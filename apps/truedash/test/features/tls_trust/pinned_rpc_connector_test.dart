import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/models.dart';
import 'package:truedash/features/tls_trust/native_tls_io.dart';
import 'package:truedash/features/tls_trust/native_tls_ports.dart';
import 'package:truenas_api/truenas_api.dart';

/// Task 6 RED contract for the Apple-only, exact-pin RPC reconnect bridge.
///
/// The deliberately small [ApplePinnedRpcMethodChannel] is an intended API:
/// the native side receives only these versioned, session-scoped messages.
void main() {
  final authority = NormalizedAuthority.parse(
    'https://NAS.example.test/api/v2.0/websocket',
  );
  final pin = PinRecord(
    leafDerSha256: 'A' * 64,
    createdAt: DateTime.utc(2026, 9, 6),
  );

  group('Apple exact-pin reconnect', () {
    test('is bounded on Apple and unavailable everywhere else', () async {
      final apple = _FakePinnedChannel();
      final connector = createReconnectForNativeTlsPlatform(
        NativeTlsPlatform.apple,
        appleChannel: apple,
      );
      final future = connector.reconnect(
        authority: authority,
        pin: pin,
        timeout: const Duration(milliseconds: 100),
        cancellation: CancellationSource().token,
      );
      expect(apple.calls, hasLength(1));
      apple.completeConnect(apple.calls.single.operationId);
      expect(await future, isA<NativePinnedVerified>());

      for (final platform in [
        NativeTlsPlatform.android,
        NativeTlsPlatform.linux,
        NativeTlsPlatform.windows,
        NativeTlsPlatform.other,
      ]) {
        final outcome = await createReconnectForNativeTlsPlatform(platform)
            .reconnect(
              authority: authority,
              pin: pin,
              timeout: const Duration(milliseconds: 100),
              cancellation: CancellationSource().token,
            );
        expect(
          outcome,
          const NativePinnedBoundaryFailure(
            NativeTlsBoundaryFailure.backendUnavailable,
          ),
        );
      }
    });

    test(
      'connect request is an exact allowlist and no transport exists early',
      () async {
        final channel = _FakePinnedChannel();
        final future =
            createReconnectForNativeTlsPlatform(
              NativeTlsPlatform.apple,
              appleChannel: channel,
            ).reconnect(
              authority: authority,
              pin: pin,
              timeout: const Duration(milliseconds: 100),
              cancellation: CancellationSource().token,
            );
        final call = channel.calls.single;
        expect(call.method, 'truedash.connectPinnedRpc');
        expect(call.arguments, <String, Object>{
          'protocolVersion': 1,
          'operationId': call.operationId,
          'host': 'nas.example.test',
          'port': 443,
          'rpcPath': '/api/v2.0/websocket',
          'leafDerSha256': 'A' * 64,
        });
        expect(call.operationId, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(
          call.arguments.keys,
          isNot(
            containsAll(<String>[
              'apiKey',
              'credential',
              'authorization',
              'headers',
              'frame',
              'profile',
              'leafDer',
              'callback',
              'url',
            ]),
          ),
        );
        expect(channel.transportMessages, isEmpty);

        channel.completeConnect(call.operationId);
        final outcome = await future;
        expect(outcome, isA<NativePinnedVerified>());
        expect(
          (outcome as NativePinnedVerified).transport,
          isA<RpcTransport>(),
        );
      },
    );

    test(
      'only an exact successful response makes a session transport available',
      () async {
        for (final malformed in <Object?>[
          null,
          <String, Object>{'protocolVersion': 1, 'operationId': 'wrong'},
          <String, Object>{
            'protocolVersion': 1,
            'operationId': '0' * 32,
            'sessionId': 'A' * 32,
          },
          <String, Object>{
            'protocolVersion': 2,
            'operationId': '0' * 32,
            'sessionId': 'b' * 32,
          },
          <String, Object>{
            'protocolVersion': 1,
            'operationId': '0' * 32,
            'sessionId': 'b' * 32,
            'extra': true,
          },
        ]) {
          final channel = _FakePinnedChannel();
          final future =
              createReconnectForNativeTlsPlatform(
                NativeTlsPlatform.apple,
                appleChannel: channel,
              ).reconnect(
                authority: authority,
                pin: pin,
                timeout: const Duration(milliseconds: 100),
                cancellation: CancellationSource().token,
              );
          channel.completeConnect(channel.calls.single.operationId, malformed);
          final outcome = await future;
          expect(outcome, isA<NativePinnedFailure>());
          expect(
            (outcome as NativePinnedFailure).failure,
            CertificateTrustFailure.malformedCertificate,
          );
          expect(channel.transportMessages, isEmpty);
        }
      },
    );

    test('the transferred transport long-polls one strict session-scoped frame at a time', () async {
      final channel = _FakePinnedChannel();
      final outcome = await _successfulReconnect(channel, authority, pin);
      final transport = outcome.transport;

      await transport.send('{"method":"core.ping"}');
      expect(
        channel.transportMessages.single,
        _Message('truedash.sendPinnedRpc', {
          'protocolVersion': 1,
          'sessionId': _FakePinnedChannel.sessionId,
          'frame': '{"method":"core.ping"}',
        }),
      );

      final received = expectLater(
        transport.inboundFrames,
        emitsInOrder(<Object>[
          '{"result":"pong"}',
          emitsError(isA<RpcTransportClosedException>()),
          emitsDone,
        ]),
      );
      expect(channel.receiveCalls, hasLength(1));
      expect(
        channel.receiveCalls.single,
        const _Message('truedash.receivePinnedRpc', {
          'protocolVersion': 1,
          'sessionId': _FakePinnedChannel.sessionId,
        }),
      );
      channel.completeReceive(<String, Object>{
        'protocolVersion': 1,
        'sessionId': _FakePinnedChannel.sessionId,
        'frame': '{"result":"pong"}',
      });
      await Future<void>.delayed(Duration.zero);
      expect(channel.receiveCalls, hasLength(2));
      channel.completeReceive(<String, Object>{
        'protocolVersion': 1,
        'sessionId': _FakePinnedChannel.sessionId,
        'frame': 7,
      });
      await received;

      await transport.close();
      await transport.close();
      expect(channel.closeCalls, [
        _Message('truedash.closePinnedRpc', {
          'protocolVersion': 1,
          'sessionId': _FakePinnedChannel.sessionId,
        }),
      ]);
    });

    test(
      'wrong receive responses and native receive errors fail closed',
      () async {
        for (final inbound in <Object?>[
          null,
          <String, Object>{
            'protocolVersion': 1,
            'sessionId': _FakePinnedChannel.sessionId,
          },
          <String, Object>{
            'protocolVersion': 2,
            'sessionId': _FakePinnedChannel.sessionId,
            'frame': 'x',
          },
          <String, Object>{
            'protocolVersion': 1,
            'sessionId': 'c' * 32,
            'frame': 'x',
          },
          <String, Object>{
            'protocolVersion': 1,
            'sessionId': _FakePinnedChannel.sessionId,
            'frame': 'x',
            'unknown': true,
          },
          <String, Object>{
            'protocolVersion': 1,
            'sessionId': _FakePinnedChannel.sessionId,
            'closed': false,
          },
          <String, Object>{
            'protocolVersion': 1,
            'sessionId': _FakePinnedChannel.sessionId,
            'frame': 'x',
            'closed': true,
          },
          StateError('native certificate detail must not escape'),
        ]) {
          final channel = _FakePinnedChannel();
          final transport = (await _successfulReconnect(
            channel,
            authority,
            pin,
          )).transport;
          final errors = transport.inboundFrames.toList();
          if (inbound is StateError) {
            channel.failReceive(inbound);
          } else {
            channel.completeReceive(inbound);
          }
          await expectLater(
            errors,
            throwsA(isA<RpcTransportClosedException>()),
          );
          expect(channel.closeCalls, hasLength(1));
        }
      },
    );

    test(
      'a closed receive response emits only a closed exception then done',
      () async {
        final channel = _FakePinnedChannel();
        final transport = (await _successfulReconnect(
          channel,
          authority,
          pin,
        )).transport;
        final received = expectLater(
          transport.inboundFrames,
          emitsInOrder(<Object>[
            emitsError(isA<RpcTransportClosedException>()),
            emitsDone,
          ]),
        );
        channel.completeReceive(const <String, Object>{
          'protocolVersion': 1,
          'sessionId': _FakePinnedChannel.sessionId,
          'closed': true,
        });
        await received;
        expect(channel.closeCalls, hasLength(1));
      },
    );

    test(
      'malformed send acknowledgements and channel errors fail closed',
      () async {
        for (final response in <Object?>[
          null,
          <String, Object>{'protocolVersion': 1},
          <String, Object>{
            'protocolVersion': 2,
            'sessionId': _FakePinnedChannel.sessionId,
          },
          <String, Object>{
            'protocolVersion': 1,
            'sessionId': _FakePinnedChannel.sessionId,
            'extra': true,
          },
          StateError('native error text must not escape'),
          const _SynchronousChannelError(),
        ]) {
          final channel = _FakePinnedChannel();
          final transport = (await _successfulReconnect(
            channel,
            authority,
            pin,
          )).transport;
          final expectedErrors = expectLater(
            transport.inboundFrames,
            emitsInOrder(<Object>[
              emitsError(isA<RpcTransportClosedException>()),
              emitsDone,
            ]),
          );
          channel.nextSendResult = response;
          await expectLater(
            transport.send('x'),
            throwsA(isA<RpcTransportClosedException>()),
          );
          await expectedErrors;
          expect(channel.closeCalls, hasLength(1));
          channel.completeReceive(const <String, Object>{
            'protocolVersion': 1,
            'sessionId': _FakePinnedChannel.sessionId,
            'closed': true,
          });
        }
      },
    );

    test(
      'malformed close acknowledgements and channel errors fail closed',
      () async {
        for (final response in <Object?>[
          <String, Object>{'protocolVersion': 1},
          StateError('native close detail must not escape'),
          const _SynchronousChannelError(),
        ]) {
          final channel = _FakePinnedChannel();
          final transport = (await _successfulReconnect(
            channel,
            authority,
            pin,
          )).transport;
          final done = expectLater(transport.inboundFrames, emitsDone);
          expect(channel.receiveCalls, hasLength(1));
          channel.nextCloseResult = response;
          await expectLater(
            transport.close(),
            throwsA(isA<RpcTransportClosedException>()),
          );
          await done;
          expect(channel.closeCalls, hasLength(1));
          // The pending fake receive must settle deterministically. Production
          // ignores it after explicit close rather than starting another poll.
          channel.completeReceive(const <String, Object>{
            'protocolVersion': 1,
            'sessionId': _FakePinnedChannel.sessionId,
            'frame': 'late',
          });
          await Future<void>.delayed(Duration.zero);
          expect(channel.receiveCalls, hasLength(1));
        }
      },
    );

    test('send bounds UTF-8 bytes rather than UTF-16 code units', () async {
      final channel = _FakePinnedChannel();
      final transport = (await _successfulReconnect(
        channel,
        authority,
        pin,
      )).transport;
      final tooLarge = List<String>.filled(262145, '😀').join();
      expect(tooLarge.length, lessThan(1024 * 1024));
      await expectLater(
        transport.send(tooLarge),
        throwsA(isA<RpcTransportClosedException>()),
      );
      expect(channel.transportMessages, isEmpty);
      expect(channel.closeCalls, hasLength(1));
    });

    test(
      'failure cleanup is shared with explicit close and is awaited',
      () async {
        for (final failure in ['send', 'receive', 'remote']) {
          final channel = _FakePinnedChannel()..holdClose = true;
          final transport = (await _successfulReconnect(
            channel,
            authority,
            pin,
          )).transport;
          final events = <Object>[];
          final subscription = transport.inboundFrames.listen(
            events.add,
            onError: events.add,
          );
          Future<void> failureFuture;
          if (failure == 'send') {
            channel.nextSendResult = StateError('native');
            failureFuture = transport.send('x').catchError((_) {});
          } else if (failure == 'receive') {
            channel.failReceive(StateError('native'));
            failureFuture = Future<void>.delayed(Duration.zero);
          } else {
            channel.completeReceive(const <String, Object>{
              'protocolVersion': 1,
              'sessionId': _FakePinnedChannel.sessionId,
              'closed': true,
            });
            failureFuture = Future<void>.delayed(Duration.zero);
          }
          await Future<void>.delayed(Duration.zero);
          final explicit = transport.close();
          var settled = false;
          explicit.whenComplete(() => settled = true);
          expect(channel.closeCalls, hasLength(1));
          await Future<void>.delayed(Duration.zero);
          expect(settled, isFalse);
          channel.completeClose();
          await failureFuture;
          await explicit;
          expect(events.whereType<RpcTransportClosedException>(), hasLength(1));
          await subscription.cancel();
        }
      },
    );

    test('timeout, cancellation, and late replies use only the operation cancel path', () async {
      final timeoutChannel = _FakePinnedChannel();
      final timedOut =
          await createReconnectForNativeTlsPlatform(
            NativeTlsPlatform.apple,
            appleChannel: timeoutChannel,
          ).reconnect(
            authority: authority,
            pin: pin,
            timeout: const Duration(milliseconds: 1),
            cancellation: CancellationSource().token,
          );
      expect(
        timedOut,
        const NativePinnedFailure(
          CertificateTrustFailure.pinnedReconnectFailed,
        ),
      );
      expect(
        timeoutChannel.cancelCalls.single.method,
        'truedash.cancelPinnedRpc',
      );
      timeoutChannel.completeConnect(timeoutChannel.calls.single.operationId);
      expect(timeoutChannel.transportMessages, isEmpty);

      final source = CancellationSource();
      final cancelledChannel = _FakePinnedChannel();
      final pending =
          createReconnectForNativeTlsPlatform(
            NativeTlsPlatform.apple,
            appleChannel: cancelledChannel,
          ).reconnect(
            authority: authority,
            pin: pin,
            timeout: const Duration(milliseconds: 100),
            cancellation: source.token,
          );
      source.cancel();
      expect(
        await pending,
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
      expect(
        cancelledChannel.cancelCalls.single.method,
        'truedash.cancelPinnedRpc',
      );

      final handoffSource = CancellationSource();
      final handoffChannel = _FakePinnedChannel();
      final handoff =
          createReconnectForNativeTlsPlatform(
            NativeTlsPlatform.apple,
            appleChannel: handoffChannel,
          ).reconnect(
            authority: authority,
            pin: pin,
            timeout: const Duration(milliseconds: 100),
            cancellation: handoffSource.token,
          );
      handoffChannel.completeConnect(handoffChannel.calls.single.operationId);
      handoffSource.cancel();
      expect(
        await handoff,
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
      // The awaited operation cancellation owns a native session that may
      // already have crossed didOpen; a late Dart reply must not add an
      // untracked second close.
      expect(handoffChannel.cancelCalls, hasLength(1));
      expect(handoffChannel.closeCalls, isEmpty);

      final ownerSource = CancellationSource();
      final ownerChannel = _FakePinnedChannel();
      final owned =
          createReconnectForNativeTlsPlatform(
            NativeTlsPlatform.apple,
            appleChannel: ownerChannel,
          ).reconnect(
            authority: authority,
            pin: pin,
            timeout: const Duration(milliseconds: 100),
            cancellation: ownerSource.token,
          );
      ownerChannel.completeConnect(ownerChannel.calls.single.operationId);
      final transferred = (await owned as NativePinnedVerified).transport;
      ownerSource.cancel();
      await transferred.send('caller-owned');
      expect(ownerChannel.transportMessages, hasLength(1));

      final preCancelled = CancellationSource()..cancel();
      final idle = _FakePinnedChannel();
      expect(
        await createReconnectForNativeTlsPlatform(
          NativeTlsPlatform.apple,
          appleChannel: idle,
        ).reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(milliseconds: 100),
          cancellation: preCancelled.token,
        ),
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
      expect(idle.calls, isEmpty);
      expect(idle.cancelCalls, isEmpty);
    });

    test('bounded cancellation waits for native cleanup in both didOpen queue orders', () async {
      for (final openedBeforeCancel in [false, true]) {
        final source = CancellationSource();
        final channel = _FakePinnedChannel()..holdCancel = true;
        final reconnect =
            createReconnectForNativeTlsPlatform(
              NativeTlsPlatform.apple,
              appleChannel: channel,
            ).reconnect(
              authority: authority,
              pin: pin,
              timeout: const Duration(milliseconds: 100),
              cancellation: source.token,
            );
        if (openedBeforeCancel) {
          // Native didOpen can precede a queued MethodChannel response.
          channel.completeConnect(channel.calls.single.operationId);
        }
        source.cancel();
        var settled = false;
        reconnect.whenComplete(() => settled = true);
        await Future<void>.delayed(Duration.zero);
        expect(channel.cancelCalls, hasLength(1));
        expect(settled, isFalse);
        channel.completeCancel();
        expect(
          await reconnect,
          const NativePinnedFailure(CertificateTrustFailure.cancelled),
        );
        expect(channel.closeCalls, isEmpty);
      }
    });

    test('maps fixed native failures separately, isolates probe identity, and retains normal public trust source', () async {
      final failureCodes = <String, CertificateTrustFailure>{
        'pinMismatch': CertificateTrustFailure.pinMismatch,
        'hostnameMismatch': CertificateTrustFailure.hostnameMismatch,
        'expiredCertificate': CertificateTrustFailure.expiredCertificate,
        'notYetValidCertificate':
            CertificateTrustFailure.notYetValidCertificate,
        'malformedCertificate': CertificateTrustFailure.malformedCertificate,
        'pinnedReconnectFailed': CertificateTrustFailure.pinnedReconnectFailed,
        'cancelled': CertificateTrustFailure.cancelled,
      };
      for (final entry in failureCodes.entries) {
        final channel = _FakePinnedChannel();
        final future =
            createReconnectForNativeTlsPlatform(
              NativeTlsPlatform.apple,
              appleChannel: channel,
            ).reconnect(
              authority: authority,
              pin: pin,
              timeout: const Duration(milliseconds: 100),
              cancellation: CancellationSource().token,
            );
        channel.completeConnect(
          channel.calls.single.operationId,
          <String, Object>{
            'protocolVersion': 1,
            'operationId': channel.calls.single.operationId,
            'failureCode': entry.key,
          },
        );
        final outcome = await future;
        expect(outcome, isA<NativePinnedFailure>());
        expect((outcome as NativePinnedFailure).failure, entry.value);
      }
      final probeChannel = _FakeProbeChannel();
      final probe =
          ApplePresentedLeafProbeBackend(
            channel: probeChannel,
            now: DateTime.now,
          ).startProbe(
            authority: authority,
            cancellation: CancellationSource().token,
          );
      final probeOperationId = probeChannel.calls.single.operationId;
      await probe.close();
      final reconnectChannel = _FakePinnedChannel();
      final reconnect =
          createReconnectForNativeTlsPlatform(
            NativeTlsPlatform.apple,
            appleChannel: reconnectChannel,
          ).reconnect(
            authority: authority,
            pin: pin,
            timeout: const Duration(milliseconds: 100),
            cancellation: CancellationSource().token,
          );
      expect(
        reconnectChannel.calls.single.operationId,
        isNot(probeOperationId),
      );
      expect(
        reconnectChannel.calls.map((call) => call.method),
        isNot(contains('truedash.capturePresentedLeaf')),
      );
      reconnectChannel.completeConnect(
        reconnectChannel.calls.single.operationId,
      );
      await reconnect;
      final source = File(
        '../../packages/truenas_api/lib/src/transport/web_socket_connector.dart',
      ).readAsStringSync();
      expect(source, contains('WebSocketChannel.connect(endpoint)'));
      expect(source, isNot(contains('badCertificateCallback')));
      expect(source, isNot(contains('allowBadCertificates')));
    });
  });
}

Future<NativePinnedVerified> _successfulReconnect(
  _FakePinnedChannel channel,
  NormalizedAuthority authority,
  PinRecord pin,
) async {
  final future =
      createReconnectForNativeTlsPlatform(
        NativeTlsPlatform.apple,
        appleChannel: channel,
      ).reconnect(
        authority: authority,
        pin: pin,
        timeout: const Duration(milliseconds: 100),
        cancellation: CancellationSource().token,
      );
  channel.completeConnect(channel.calls.single.operationId);
  return await future as NativePinnedVerified;
}

final class _FakePinnedChannel implements ApplePinnedRpcMethodChannel {
  static const sessionId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  static const _unset = _Unset();
  final calls = <_Message>[];
  final transportMessages = <_Message>[];
  final closeCalls = <_Message>[];
  final cancelCalls = <_Message>[];
  final receiveCalls = <_Message>[];
  final _pendingConnects = <String, Completer<Object?>>{};
  final _pendingReceives = <Completer<Object?>>[];
  Object? nextSendResult = _unset;
  Object? nextCloseResult = _unset;
  bool holdClose = false;
  Completer<Object?>? _pendingClose;
  bool holdCancel = false;
  Completer<Object?>? _pendingCancel;

  @override
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments) {
    final message = _Message(method, Map<String, Object>.from(arguments));
    if (method == 'truedash.connectPinnedRpc') {
      calls.add(message);
      return (_pendingConnects[message.operationId] = Completer<Object?>())
          .future;
    }
    if (method == 'truedash.cancelPinnedRpc') {
      cancelCalls.add(message);
      if (holdCancel) return (_pendingCancel = Completer<Object?>()).future;
    }
    if (method == 'truedash.receivePinnedRpc') {
      receiveCalls.add(message);
      final pending = Completer<Object?>();
      _pendingReceives.add(pending);
      return pending.future;
    }
    if (method == 'truedash.sendPinnedRpc') {
      transportMessages.add(message);
      return _respond(nextSendResult);
    }
    if (method == 'truedash.closePinnedRpc') {
      closeCalls.add(message);
      if (holdClose) return (_pendingClose = Completer<Object?>()).future;
      return _respond(nextCloseResult);
    }
    return Future<Object?>.value(<String, Object>{
      'protocolVersion': 1,
      'sessionId': sessionId,
    });
  }

  void completeConnect(String operationId, [Object? response = _unset]) {
    _pendingConnects[operationId]!.complete(
      identical(response, _unset)
          ? <String, Object>{
              'protocolVersion': 1,
              'operationId': operationId,
              'sessionId': sessionId,
            }
          : response,
    );
  }

  Future<Object?> _respond(Object? result) {
    if (result is _SynchronousChannelError) {
      throw StateError('synchronous native error text must not escape');
    }
    if (result is StateError) return Future<Object?>.error(result);
    return Future<Object?>.value(
      identical(result, _unset)
          ? <String, Object>{'protocolVersion': 1, 'sessionId': sessionId}
          : result,
    );
  }

  void completeReceive(Object? response) {
    final pending = _pendingReceives.removeAt(0);
    pending.complete(response);
  }

  void failReceive(Object error) {
    final pending = _pendingReceives.removeAt(0);
    pending.completeError(error);
  }

  void completeClose([Object? response = _unset]) {
    _pendingClose!.complete(
      identical(response, _unset)
          ? <String, Object>{'protocolVersion': 1, 'sessionId': sessionId}
          : response,
    );
  }

  void completeCancel() => _pendingCancel!.complete(<String, Object>{
    'protocolVersion': 1,
    'operationId': calls.single.operationId,
    'failureCode': 'cancelled',
  });
}

final class _SynchronousChannelError {
  const _SynchronousChannelError();
}

final class _Unset {
  const _Unset();
}

final class _FakeProbeChannel implements AppleTlsMethodChannel {
  final calls = <_Message>[];

  @override
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments) {
    calls.add(_Message(method, Map<String, Object>.from(arguments)));
    return Future<Object?>.value(null);
  }
}

final class _Message {
  const _Message(this.method, this.arguments);
  final String method;
  final Map<String, Object> arguments;
  String get operationId => arguments['operationId']! as String;

  @override
  bool operator ==(Object other) =>
      other is _Message &&
      method == other.method &&
      _sameMap(arguments, other.arguments);
  @override
  int get hashCode => Object.hash(method, Object.hashAll(arguments.entries));
}

bool _sameMap(Map<String, Object> a, Map<String, Object> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);
