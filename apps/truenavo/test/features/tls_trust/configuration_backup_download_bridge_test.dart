import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/tls_trust/models.dart';
import 'package:truenavo/features/tls_trust/native_tls_io.dart';
import 'package:truenavo/features/tls_trust/native_tls_ports.dart';
import 'package:truenas_api/truenas_api.dart';

const _session = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _url = '/_download/71?auth_token=${'S' * 64}';

void main() {
  test(
    'Android bridge forwards only existing session job and strict relative URL',
    () async {
      final channel = _Channel();
      final transport = await _connect(channel);
      addTearDown(transport.close);
      final downloader = transport as ConfigurationBackupDownloadTransport;
      expect(downloader.configurationBackupDownloadSupported, isTrue);
      final bytes = await downloader.downloadConfigurationBackup(
        relativeUrl: _url,
        jobId: 71,
      );
      expect(bytes, [1, 2, 3]);
      final call = channel.calls.singleWhere(
        (e) => e.$1 == 'truenavo.downloadConfigurationBackup',
      );
      expect(call.$2, {
        'protocolVersion': 1,
        'sessionId': _session,
        'jobId': 71,
        'relativeUrl': _url,
      });
      bytes.fillRange(0, bytes.length, 0);
    },
  );
  test('shared Apple bridge advertises unsupported and makes no download invocation', () async {
    final channel = _Channel();
    final transport = await _connect(channel, NativeTlsPlatform.apple);
    addTearDown(transport.close);
    final downloader = transport as ConfigurationBackupDownloadTransport;
    expect(downloader.configurationBackupDownloadSupported, isFalse);
    final before = channel.calls.length;
    await expectLater(
      downloader.downloadConfigurationBackup(relativeUrl: _url, jobId: 71),
      throwsA(isA<RpcTransportClosedException>()),
    );
    expect(channel.calls.length, before);
  });
  for (final url in [
    'https://evil.invalid$_url',
    '//evil.invalid$_url',
    '$_url&extra=1',
    '$_url#fragment',
    '$_url\n',
    '/_download/072?auth_token=${'S' * 64}',
    '/_download/71?auth_token=short',
    '/_download/71?auth_token=${'S' * 513}',
  ]) {
    test(
      'malformed or absolute URL never crosses channel: ${url.length}',
      () async {
        final channel = _Channel();
        final transport = await _connect(channel);
        addTearDown(transport.close);
        final before = channel.calls.length;
        await expectLater(
          (transport as ConfigurationBackupDownloadTransport)
              .downloadConfigurationBackup(relativeUrl: url, jobId: 71),
          throwsA(isA<RpcTransportClosedException>()),
        );
        expect(channel.calls.length, before);
      },
    );
  }
  for (final id in [0, -1, 72, 9007199254740992]) {
    test('wrong or unsafe job $id makes zero download calls', () async {
      final channel = _Channel();
      final transport = await _connect(channel);
      addTearDown(transport.close);
      final before = channel.calls.length;
      await expectLater(
        (transport as ConfigurationBackupDownloadTransport)
            .downloadConfigurationBackup(relativeUrl: _url, jobId: id),
        throwsA(isA<RpcTransportClosedException>()),
      );
      expect(channel.calls.length, before);
    });
  }
  for (final fault in [
    'protocol',
    'session',
    'job',
    'extra',
    'empty',
    'oversized',
    'throws',
  ]) {
    test(
      'malformed $fault response fails sanitized and zeroes received bytes',
      () async {
        final channel = _Channel()..fault = fault;
        final transport = await _connect(channel);
        addTearDown(transport.close);
        await expectLater(
          (transport as ConfigurationBackupDownloadTransport)
              .downloadConfigurationBackup(relativeUrl: _url, jobId: 71),
          throwsA(isA<RpcTransportClosedException>()),
        );
        expect(channel.buffer.every((b) => b == 0), isTrue);
      },
    );
  }
  test(
    'concurrent download rejected and close destroys late byte response',
    () async {
      final pending = Completer<Object?>();
      final channel = _Channel()..pending = pending;
      final transport = await _connect(channel);
      final downloader = transport as ConfigurationBackupDownloadTransport;
      final first = downloader.downloadConfigurationBackup(
        relativeUrl: _url,
        jobId: 71,
      );
      final observed = expectLater(
        first,
        throwsA(isA<RpcTransportClosedException>()),
      );
      final count = channel.calls.length;
      await expectLater(
        downloader.downloadConfigurationBackup(relativeUrl: _url, jobId: 71),
        throwsA(isA<RpcTransportClosedException>()),
      );
      expect(channel.calls.length, count);
      await transport.close();
      pending.complete({
        'protocolVersion': 1,
        'sessionId': _session,
        'jobId': 71,
        'bytes': channel.buffer,
      });
      await observed;
      expect(channel.buffer, [0, 0, 0]);
      expect(downloader.configurationBackupDownloadSupported, isFalse);
    },
  );
}

Future<RpcTransport> _connect(
  _Channel channel, [
  NativeTlsPlatform platform = NativeTlsPlatform.android,
]) async {
  final result =
      await createReconnectForNativeTlsPlatform(
        platform,
        probeChannel: channel,
      ).reconnect(
        authority: NormalizedAuthority.parse(
          'https://nas.example.test/api/current',
        ),
        pin: PinRecord(
          leafDerSha256: 'AB' * 32,
          createdAt: DateTime.utc(2026, 9, 14),
        ),
        timeout: const Duration(seconds: 1),
        cancellation: CancellationSource().token,
      );
  return (result as NativePinnedVerified).transport;
}

class _Channel implements PinnedRpcChannel {
  final calls = <(String, Map<String, Object?>)>[];
  Uint8List buffer = Uint8List.fromList([1, 2, 3]);
  String? fault;
  Completer<Object?>? pending;
  @override
  Future<Object?> invokeMethod(
    String method,
    Map<String, Object?> arguments,
  ) async {
    calls.add((method, arguments));
    if (method == 'truenavo.connectPinnedRpc') {
      return {
        'protocolVersion': 1,
        'operationId': arguments['operationId'],
        'sessionId': _session,
      };
    }
    if (method == 'truenavo.closePinnedRpc') {
      return {'protocolVersion': 1, 'sessionId': _session};
    }
    if (method == 'truenavo.downloadConfigurationBackup') {
      if (fault == 'throws') {
        buffer.fillRange(0, buffer.length, 0);
        throw StateError('synthetic-secret-platform-error');
      }
      if (pending != null) return pending!.future;
      if (fault == 'empty') buffer = Uint8List(0);
      if (fault == 'oversized') {
        buffer = Uint8List(16 * 1024 * 1024 + 1)
          ..fillRange(0, 16 * 1024 * 1024 + 1, 1);
      }
      return {
        'protocolVersion': fault == 'protocol' ? 2 : 1,
        'sessionId': fault == 'session' ? 'wrong' : _session,
        'jobId': fault == 'job' ? 72 : 71,
        'bytes': buffer,
        if (fault == 'extra') 'private': true,
      };
    }
    throw StateError('Unexpected synthetic bridge method');
  }
}
