import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/tls_trust/models.dart';
import 'package:truenavo/features/tls_trust/native_tls_io.dart';
import 'package:truenavo/features/tls_trust/native_tls_ports.dart';
import 'package:truenas_api/truenas_api.dart';

const _session = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _token = 'S' * 64;
const _method = 'truenavo.uploadConfigurationRestore';

void main() {
  test(
    'Android upload uses only the existing session and consumes bytes',
    () async {
      final channel = _Channel();
      final transport = await _connect(channel);
      addTearDown(transport.close);
      final uploader = transport as ConfigurationRestoreUploadTransport;
      expect(uploader.configurationRestoreUploadSupported, isTrue);
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(
        await uploader.uploadConfigurationRestore(token: _token, bytes: bytes),
        71,
      );
      expect(channel.uploadKeys, {
        'protocolVersion',
        'sessionId',
        'token',
        'bytes',
      });
      expect(channel.uploadSession, _session);
      expect(channel.uploadTokenMatches, isTrue);
      expect(channel.receivedSnapshot, [1, 2, 3]);
      expect(bytes, [0, 0, 0]);
    },
  );
  test(
    'Apple bridge is unsupported and consumes input without channel upload',
    () async {
      final channel = _Channel();
      final transport = await _connect(channel, NativeTlsPlatform.apple);
      addTearDown(transport.close);
      final uploader = transport as ConfigurationRestoreUploadTransport;
      expect(uploader.configurationRestoreUploadSupported, isFalse);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        uploader.uploadConfigurationRestore(token: _token, bytes: bytes),
        throwsA(isA<RpcTransportClosedException>()),
      );
      expect(channel.uploads, 0);
      expect(bytes, [0, 0, 0]);
    },
  );
  for (final token in [
    '',
    'short',
    'S' * 513,
    '${'S' * 64}\n',
    '${'S' * 63}+',
    '${'S' * 63}/',
    ' $_token',
  ]) {
    test(
      'invalid token of length ${token.length} never crosses native channel',
      () async {
        final channel = _Channel();
        final transport = await _connect(channel);
        addTearDown(transport.close);
        final bytes = Uint8List.fromList([1, 2, 3]);
        await expectLater(
          (transport as ConfigurationRestoreUploadTransport)
              .uploadConfigurationRestore(token: token, bytes: bytes),
          throwsA(isA<RpcTransportClosedException>()),
        );
        expect(channel.uploads, 0);
        expect(bytes, [0, 0, 0]);
      },
    );
  }
  for (final length in [0, 10 * 1024 * 1024 + 1]) {
    test('invalid byte length $length is wiped without upload', () async {
      final channel = _Channel();
      final transport = await _connect(channel);
      addTearDown(transport.close);
      final bytes = Uint8List(length)..fillRange(0, length, 1);
      await expectLater(
        (transport as ConfigurationRestoreUploadTransport)
            .uploadConfigurationRestore(token: _token, bytes: bytes),
        throwsA(isA<RpcTransportClosedException>()),
      );
      expect(channel.uploads, 0);
      expect(bytes.every((b) => b == 0), isTrue);
    });
  }
  for (final receipt in [null, true, '71', 0, -1, 9007199254740992, 71.0]) {
    test(
      'non-positive or non-exact integer receipt $receipt is sanitized',
      () async {
        final channel = _Channel()..job = receipt;
        final transport = await _connect(channel);
        addTearDown(transport.close);
        final bytes = Uint8List.fromList([1, 2, 3]);
        await expectLater(
          (transport as ConfigurationRestoreUploadTransport)
              .uploadConfigurationRestore(token: _token, bytes: bytes),
          throwsA(isA<RpcTransportClosedException>()),
        );
        expect(channel.uploads, 1);
        expect(bytes, [0, 0, 0]);
      },
    );
  }
  for (final fault in ['protocol', 'session', 'extra', 'throws', 'notMap']) {
    test(
      'malformed $fault response consumes bytes and exposes no platform error',
      () async {
        final channel = _Channel()..fault = fault;
        final transport = await _connect(channel);
        addTearDown(transport.close);
        final bytes = Uint8List.fromList([1, 2, 3]);
        await expectLater(
          (transport as ConfigurationRestoreUploadTransport)
              .uploadConfigurationRestore(token: _token, bytes: bytes),
          throwsA(isA<RpcTransportClosedException>()),
        );
        expect(bytes, [0, 0, 0]);
      },
    );
  }
  test(
    'maximum safe integer job and exact maximum file size are accepted',
    () async {
      final channel = _Channel()..job = 9007199254740991;
      final transport = await _connect(channel);
      addTearDown(transport.close);
      final bytes = Uint8List(10 * 1024 * 1024)
        ..fillRange(0, 10 * 1024 * 1024, 1);
      expect(
        await (transport as ConfigurationRestoreUploadTransport)
            .uploadConfigurationRestore(token: _token, bytes: bytes),
        9007199254740991,
      );
      expect(bytes.every((b) => b == 0), isTrue);
    },
  );
  test('pending upload retains its input until settlement and blocks another transfer', () async {
    final channel = _Channel()..pending = Completer<Object?>();
    final transport = await _connect(channel);
    addTearDown(transport.close);
    final uploader = transport as ConfigurationRestoreUploadTransport;
    final bytes = Uint8List.fromList([1, 2, 3]);
    final first = uploader.uploadConfigurationRestore(
      token: _token,
      bytes: bytes,
    );
    final observed = expectLater(
      first,
      throwsA(isA<RpcTransportClosedException>()),
    );
    final duplicate = Uint8List.fromList([4, 5]);
    await expectLater(
      uploader.uploadConfigurationRestore(token: _token, bytes: duplicate),
      throwsA(isA<RpcTransportClosedException>()),
    );
    await expectLater(
      (transport as ConfigurationBackupDownloadTransport)
          .downloadConfigurationBackup(
            relativeUrl: '/_download/71?auth_token=$_token',
            jobId: 71,
          ),
      throwsA(isA<RpcTransportClosedException>()),
    );
    expect(channel.uploads, 1);
    expect(channel.downloads, 0);
    expect(duplicate, [0, 0]);
    expect(bytes, [1, 2, 3]);
    await transport.close();
    expect(bytes, [1, 2, 3]);
    channel.pending!.complete({
      'protocolVersion': 1,
      'sessionId': _session,
      'jobId': 71,
    });
    await observed;
    expect(bytes, [0, 0, 0]);
    expect(uploader.configurationRestoreUploadSupported, isFalse);
  });
  test('active backup download rejects upload before native channel', () async {
    final channel = _Channel()..pendingDownload = Completer<Object?>();
    final transport = await _connect(channel);
    addTearDown(transport.close);
    final download = (transport as ConfigurationBackupDownloadTransport)
        .downloadConfigurationBackup(
          relativeUrl: '/_download/71?auth_token=$_token',
          jobId: 71,
        );
    final bytes = Uint8List.fromList([1]);
    await expectLater(
      (transport as ConfigurationRestoreUploadTransport)
          .uploadConfigurationRestore(token: _token, bytes: bytes),
      throwsA(isA<RpcTransportClosedException>()),
    );
    expect(channel.uploads, 0);
    expect(bytes, [0]);
    channel.pendingDownload!.complete({
      'protocolVersion': 1,
      'sessionId': _session,
      'jobId': 71,
      'bytes': Uint8List.fromList([2]),
    });
    final downloaded = await download;
    downloaded.fillRange(0, downloaded.length, 0);
  });
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
  int uploads = 0, downloads = 0;
  Object? job = 71;
  String? fault, uploadSession;
  bool uploadTokenMatches = false;
  Set<String>? uploadKeys;
  List<int>? receivedSnapshot;
  Completer<Object?>? pending, pendingDownload;
  @override
  Future<Object?> invokeMethod(
    String method,
    Map<String, Object?> arguments,
  ) async {
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
      downloads++;
      return pendingDownload!.future;
    }
    if (method != _method) {
      throw StateError('Unexpected synthetic bridge method');
    }
    uploads++;
    uploadKeys = arguments.keys.toSet();
    uploadSession = arguments['sessionId'] as String?;
    uploadTokenMatches = arguments['token'] == _token;
    receivedSnapshot = (arguments['bytes'] as Uint8List).take(3).toList();
    if (fault == 'throws') {
      throw StateError('synthetic-private-platform-failure');
    }
    if (fault == 'notMap') return true;
    if (pending != null) return pending!.future;
    return {
      'protocolVersion': fault == 'protocol' ? 2 : 1,
      'sessionId': fault == 'session' ? 'wrong' : _session,
      'jobId': job,
      if (fault == 'extra') 'private': true,
    };
  }
}
