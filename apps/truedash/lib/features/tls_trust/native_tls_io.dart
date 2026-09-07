import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:truenas_api/truenas_api.dart';

import 'certificate_facts.dart';
import 'der_x509_parser.dart';
import 'models.dart';
import 'native_tls_ports.dart';

export 'der_x509_parser.dart' show parsePresentedLeafDer;

const _protocolVersion = 1;
const _maximumDerBytes = 64 * 1024;
const _captureMethod = 'truedash.capturePresentedLeaf';
const _cancelMethod = 'truedash.cancelPresentedLeaf';
const _pinnedConnectMethod = 'truedash.connectPinnedRpc';
const _pinnedCancelMethod = 'truedash.cancelPinnedRpc';
const _pinnedSendMethod = 'truedash.sendPinnedRpc';
const _pinnedReceiveMethod = 'truedash.receivePinnedRpc';
const _pinnedCloseMethod = 'truedash.closePinnedRpc';

/// The deliberately tiny bridge used by the native capture adapters.
abstract interface class PresentedLeafProbeChannel {
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments);
}

final class _FlutterPresentedLeafProbeChannel
    implements PresentedLeafProbeChannel {
  const _FlutterPresentedLeafProbeChannel();
  static const _channel = MethodChannel('truedash.presented_leaf_probe.v1');

  @override
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments) =>
      _channel.invokeMethod<Object?>(method, arguments);
}

/// The intentionally small, transport-only native reconnect bridge.
abstract interface class PinnedRpcChannel {
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments);
}

final class _FlutterPinnedRpcChannel implements PinnedRpcChannel {
  const _FlutterPinnedRpcChannel();
  static const _channel = MethodChannel('truedash.pinned_rpc.v1');

  @override
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments) =>
      _channel.invokeMethod<Object?>(method, arguments);
}

enum NativeTlsPlatform { apple, android, linux, windows, other }

/// The set of platforms whose runner registers the bridge channels.
bool _hasNativeBridge(NativeTlsPlatform platform) =>
    platform == NativeTlsPlatform.apple ||
    platform == NativeTlsPlatform.android;

NativeTlsPlatform currentNativeTlsPlatform() {
  if (Platform.isIOS || Platform.isMacOS) return NativeTlsPlatform.apple;
  if (Platform.isAndroid) return NativeTlsPlatform.android;
  if (Platform.isLinux) return NativeTlsPlatform.linux;
  if (Platform.isWindows) return NativeTlsPlatform.windows;
  return NativeTlsPlatform.other;
}

NativeCertificateProbe createProbe() =>
    createProbeForNativeTlsPlatform(currentNativeTlsPlatform());

NativeCertificateProbe createProbeForNativeTlsPlatform(
  NativeTlsPlatform platform, {
  PresentedLeafProbeChannel? probeChannel,
  DateTime Function()? now,
}) {
  if (!_hasNativeBridge(platform)) return _UnavailableProbe();
  return BoundedNativeTlsPorts(
    backend: PresentedLeafProbeBackend(
      channel: probeChannel ?? const _FlutterPresentedLeafProbeChannel(),
      now: now ?? DateTime.now,
    ),
  );
}

PinnedRpcConnector createReconnect() =>
    createReconnectForNativeTlsPlatform(currentNativeTlsPlatform());

PinnedRpcConnector createReconnectForNativeTlsPlatform(
  NativeTlsPlatform platform, {
  PinnedRpcChannel? probeChannel,
}) {
  if (!_hasNativeBridge(platform)) return _UnavailableReconnect();
  return BoundedNativeTlsPorts(
    backend: PinnedRpcBackend(
      channel: probeChannel ?? const _FlutterPinnedRpcChannel(),
    ),
  );
}

final class _UnavailableProbe implements NativeCertificateProbe {
  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    validateNativeTlsTimeout(timeout);
    return Future.value(
      cancellation.isCancelled
          ? const NativeProbeFailure(CertificateTrustFailure.cancelled)
          : const NativeProbeBoundaryFailure(
              NativeTlsBoundaryFailure.backendUnavailable,
            ),
    );
  }
}

final class _UnavailableReconnect implements PinnedRpcConnector {
  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    validateNativeTlsTimeout(timeout);
    return Future.value(
      cancellation.isCancelled
          ? const NativePinnedFailure(CertificateTrustFailure.cancelled)
          : const NativePinnedBoundaryFailure(
              NativeTlsBoundaryFailure.backendUnavailable,
            ),
    );
  }
}

/// Native, capture-only backend. It intentionally has no reconnect path.
final class PresentedLeafProbeBackend implements NativeTlsAttemptBackend {
  PresentedLeafProbeBackend({
    required this._channel,
    required DateTime Function() now,
  }) : _policy = CertificateFactsPolicy(now: now);

  final PresentedLeafProbeChannel _channel;
  final CertificateFactsPolicy _policy;

  @override
  NativeProbeAttempt startProbe({
    required NormalizedAuthority authority,
    required CancellationToken cancellation,
  }) {
    final attempt = _ProbeAttempt(
      operationId: _newOperationId(),
      channel: _channel,
      policy: _policy,
      authority: authority,
      cancellation: cancellation,
    );
    attempt.start();
    return attempt;
  }

  @override
  NativePinnedAttempt startReconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required CancellationToken cancellation,
  }) => throw UnsupportedError('Pinned reconnect is not implemented.');
}

/// A separate backend from the capture-only probe; it owns no certificate
/// capture capability and sends no application frames during connection.
final class PinnedRpcBackend implements NativeTlsAttemptBackend {
  PinnedRpcBackend({required this.channel});
  final PinnedRpcChannel channel;

  @override
  NativeProbeAttempt startProbe({
    required NormalizedAuthority authority,
    required CancellationToken cancellation,
  }) =>
      throw UnsupportedError('Pinned RPC backend cannot capture certificates.');

  @override
  NativePinnedAttempt startReconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required CancellationToken cancellation,
  }) {
    final attempt = _PinnedAttempt(
      operationId: _newOperationId(),
      authority: authority,
      pin: pin,
      cancellation: cancellation,
      channel: channel,
    );
    attempt.start();
    return attempt;
  }
}

final class _PinnedAttempt implements NativePinnedAttempt {
  _PinnedAttempt({
    required this.operationId,
    required this.authority,
    required this.pin,
    required this.cancellation,
    required this.channel,
  });
  final String operationId;
  final NormalizedAuthority authority;
  final PinRecord pin;
  final CancellationToken cancellation;
  final PinnedRpcChannel channel;
  final _outcome = Completer<NativePinnedOutcome>();
  CancellationRegistration? _registration;
  Future<void>? _closeFuture;
  Future<void>? _discardFuture;
  Future<void>? _transportCloseFuture;
  Future<void>? _lateTransportCloseFuture;
  _PinnedRpcTransport? _transport;
  var _transferred = false;
  var _discardRequested = false;

  void start() {
    _registration = cancellation.register(() {
      _complete(const NativePinnedFailure(CertificateTrustFailure.cancelled));
    });
    if (cancellation.isCancelled) return;
    try {
      channel
          .invokeMethod(_pinnedConnectMethod, <String, Object?>{
            'protocolVersion': _protocolVersion,
            'operationId': operationId,
            'host': authority.host,
            'port': authority.port,
            'rpcPath': authority.rpcConnectionUri.path.isEmpty
                ? '/'
                : authority.rpcConnectionUri.path,
            'leafDerSha256': pin.leafDerSha256,
          })
          .then(_received, onError: (_, _) => _complete(_malformed()));
    } catch (_) {
      _complete(_malformed());
    }
  }

  void _received(Object? response) {
    final decoded = _decodePinnedConnect(response, operationId);
    if (_outcome.isCompleted || cancellation.isCancelled || _discardRequested) {
      final sessionId = decoded.sessionId;
      if (sessionId != null) _closeLateTransport(sessionId);
      return;
    }
    final failure = decoded.failure;
    if (failure != null) {
      _complete(NativePinnedFailure(failure));
      return;
    }
    final sessionId = decoded.sessionId!;
    _transport = _PinnedRpcTransport(channel, sessionId);
    _complete(NativePinnedVerified(_transport!));
  }

  NativePinnedOutcome _malformed() =>
      const NativePinnedFailure(CertificateTrustFailure.malformedCertificate);
  void _complete(NativePinnedOutcome value) {
    if (!_outcome.isCompleted) _outcome.complete(value);
  }

  @override
  Future<NativePinnedOutcome> get outcome => _outcome.future;
  @override
  void transferTransport() => _transferred = true;

  @override
  Future<void> discardTransport() {
    _discardRequested = true;
    return _discardFuture ??= _discardTransport();
  }

  Future<void> _discardTransport() async {
    final transport = _transport;
    if (transport != null) await _closeTransport(transport);
  }

  void _closeLateTransport(String sessionId) {
    final transport = _PinnedRpcTransport(channel, sessionId);
    final close = _closeTransport(transport);
    // A session delivered while cleanup is still pending remains owned by this
    // attempt, so its close failure must remain observable to the boundary.
    if (!_closeSettled) {
      _lateTransportCloseFuture ??= close;
      return;
    }
    unawaited(_ignoreLateTransportClose(close));
  }

  var _closeSettled = false;

  Future<void> _ignoreLateTransportClose(Future<void> close) async {
    try {
      await close;
    } catch (_) {
      // A late native response cannot surface an asynchronous platform error.
    }
  }

  Future<void> _closeTransport(_PinnedRpcTransport transport) =>
      _transportCloseFuture ??= transport.close();

  @override
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    try {
      _registration?.dispose();
      if (_transferred) return;
      final transport = _transport;
      if (transport != null) {
        if (cancellation.isCancelled || _discardRequested) {
          await _closeTransport(transport);
        }
        _complete(const NativePinnedFailure(CertificateTrustFailure.cancelled));
        return;
      }
      final response = await channel.invokeMethod(
        _pinnedCancelMethod,
        <String, Object?>{
          'protocolVersion': _protocolVersion,
          'operationId': operationId,
        },
      );
      if (!_cancelAcknowledged(response, operationId)) {
        throw StateError('Invalid cancel acknowledgement.');
      }
      // By the operation ACK, every late session that began before the
      // cancellation boundary settles has registered its shared close future.
      await _lateTransportCloseFuture;
      _complete(const NativePinnedFailure(CertificateTrustFailure.cancelled));
    } finally {
      _closeSettled = true;
    }
  }
}

typedef _PinnedConnectResult = ({
  String? sessionId,
  CertificateTrustFailure? failure,
});

_PinnedConnectResult _decodePinnedConnect(Object? raw, String operationId) {
  final map = _stringMap(raw);
  if (map == null ||
      map['protocolVersion'] != _protocolVersion ||
      map['operationId'] != operationId) {
    return (
      sessionId: null,
      failure: CertificateTrustFailure.malformedCertificate,
    );
  }
  if (map.containsKey('sessionId') &&
      map.length == 3 &&
      _validId(map['sessionId'])) {
    return (sessionId: map['sessionId']! as String, failure: null);
  }
  if (map.containsKey('failureCode') && map.length == 3) {
    final failure = switch (map['failureCode']) {
      'pinMismatch' => CertificateTrustFailure.pinMismatch,
      'hostnameMismatch' => CertificateTrustFailure.hostnameMismatch,
      'expiredCertificate' => CertificateTrustFailure.expiredCertificate,
      'notYetValidCertificate' =>
        CertificateTrustFailure.notYetValidCertificate,
      'malformedCertificate' => CertificateTrustFailure.malformedCertificate,
      'pinnedReconnectFailed' => CertificateTrustFailure.pinnedReconnectFailed,
      'cancelled' => CertificateTrustFailure.cancelled,
      _ => CertificateTrustFailure.malformedCertificate,
    };
    return (sessionId: null, failure: failure);
  }
  return (
    sessionId: null,
    failure: CertificateTrustFailure.malformedCertificate,
  );
}

bool _cancelAcknowledged(Object? raw, String operationId) {
  final map = _stringMap(raw);
  return map != null &&
      map.length == 3 &&
      map['protocolVersion'] == _protocolVersion &&
      map['operationId'] == operationId &&
      map['failureCode'] == 'cancelled';
}

Map<String, Object?>? _stringMap(Object? value) {
  if (value is! Map) return null;
  final map = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String || map.containsKey(entry.key)) return null;
    map[entry.key as String] = entry.value;
  }
  return map;
}

bool _validId(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

final class _PinnedRpcTransport implements RpcTransport {
  _PinnedRpcTransport(this._channel, this._sessionId);
  final PinnedRpcChannel _channel;
  final String _sessionId;
  final _frames = StreamController<String>();
  bool _started = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  Stream<String> get inboundFrames {
    if (!_started) {
      _started = true;
      _poll();
    }
    return _frames.stream;
  }

  @override
  Future<void> send(String frame) async {
    if (_closed) {
      throw const RpcTransportClosedException();
    }
    if (utf8.encode(frame).length > 1024 * 1024) {
      await _failClosed();
      throw const RpcTransportClosedException();
    }
    try {
      final response = await _channel.invokeMethod(_pinnedSendMethod, {
        'protocolVersion': _protocolVersion,
        'sessionId': _sessionId,
        'frame': frame,
      });
      if (_closed || !_ack(response)) {
        throw const RpcTransportClosedException();
      }
    } catch (_) {
      await _failClosed();
      throw const RpcTransportClosedException();
    }
  }

  void _poll() {
    if (_closed) return;
    Future<Object?>.sync(
      () => _channel.invokeMethod(_pinnedReceiveMethod, {
        'protocolVersion': _protocolVersion,
        'sessionId': _sessionId,
      }),
    ).then(
      (response) async {
        if (_closed) return;
        final map = _stringMap(response);
        if (map == null ||
            map['protocolVersion'] != _protocolVersion ||
            map['sessionId'] != _sessionId) {
          _failClosed();
          return;
        }
        if (map.length == 3 && map['frame'] is String) {
          final frame = map['frame']! as String;
          if (utf8.encode(frame).length > 1024 * 1024) {
            await _failClosed();
            return;
          }
          _frames.add(frame);
          // This receive has settled before its `then` callback runs. Start
          // the next one directly: there is still exactly one in flight.
          _poll();
          return;
        }
        if (map.length == 3 && map['closed'] == true) {
          _failClosed();
          return;
        }
        _failClosed();
      },
      onError: (_, _) {
        _failClosed();
      },
    );
  }

  bool _ack(Object? value) {
    final map = _stringMap(value);
    return map != null &&
        map.length == 2 &&
        map['protocolVersion'] == _protocolVersion &&
        map['sessionId'] == _sessionId;
  }

  Future<void> _failClosed() =>
      _closeFuture ??= _finishClose(reportFailure: true, validateAck: false);

  Future<void> _finishClose({
    required bool reportFailure,
    required bool validateAck,
  }) async {
    _closed = true;
    // A stream error with no subscriber is an uncaught zone error.  The
    // transport is still closed in that case; an attached listener receives
    // exactly one typed error followed by done.
    if (reportFailure && _frames.hasListener) {
      _frames.addError(const RpcTransportClosedException());
    }
    var valid = true;
    try {
      final response = await _nativeClose();
      valid = !validateAck || _ack(response);
    } catch (_) {
      valid = false;
      // The stream boundary intentionally exposes only its typed closed
      // error, never a platform-channel exception or message.
    }
    await _closeFrames();
    if (validateAck && !valid) throw const RpcTransportClosedException();
  }

  @override
  Future<void> close() =>
      _closeFuture ??= _finishClose(reportFailure: false, validateAck: true);

  // A single-subscription controller's close future waits until a listener
  // observes done. Explicit close must not wait for a caller that has not yet
  // subscribed to inboundFrames (or for a native receive that is still held).
  // A late receive callback is ignored by _poll because _closed is set first.
  Future<void> _closeFrames() {
    final hadListener = _frames.hasListener;
    final closed = _frames.close();
    return hadListener ? closed : Future<void>.value();
  }

  Future<Object?> _nativeClose() => _channel.invokeMethod(_pinnedCloseMethod, {
    'protocolVersion': _protocolVersion,
    'sessionId': _sessionId,
  });
}

final class _ProbeAttempt implements NativeProbeAttempt {
  _ProbeAttempt({
    required this.operationId,
    required this._channel,
    required this._policy,
    required this.authority,
    required this._cancellation,
  });

  final String operationId;
  final PresentedLeafProbeChannel _channel;
  final CertificateFactsPolicy _policy;
  final NormalizedAuthority authority;
  final CancellationToken _cancellation;
  final _outcome = Completer<CertificateProbeResult>();
  CancellationRegistration? _registration;
  Future<void>? _closeFuture;
  var _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _registration = _cancellation.register(() {
      _complete(
        CertificateProbeResult.failed(CertificateTrustFailure.cancelled),
      );
    });
    // Registration invokes synchronously for an already-cancelled token.
    // Avoid creating native work once cancellation is authoritative.
    if (_cancellation.isCancelled) return;
    // The method invocation is the only native operation. Its payload has no
    // protocol/application data, credentials, pins, or callback capability.
    Future<Object?> response;
    try {
      response = _channel.invokeMethod(_captureMethod, <String, Object?>{
        'protocolVersion': _protocolVersion,
        'operationId': operationId,
        'host': authority.host,
        'port': authority.port,
      });
    } catch (_) {
      _complete(
        CertificateProbeResult.failed(
          CertificateTrustFailure.malformedCertificate,
        ),
      );
      return;
    }
    response.then(
      _onResponse,
      onError: (_, _) {
        _complete(
          CertificateProbeResult.failed(
            CertificateTrustFailure.malformedCertificate,
          ),
        );
      },
    );
  }

  void _onResponse(Object? value) {
    if (_outcome.isCompleted || _cancellation.isCancelled) return;
    final decoded = _decodeResponse(value, operationId);
    if (decoded is _DecodedFailure) {
      _complete(CertificateProbeResult.failed(decoded.failure));
      return;
    }
    final leaf = decoded as _DecodedLeaf;
    try {
      final facts = parsePresentedLeafDer(leaf.der);
      _complete(
        _policy.assess(
          authority,
          NativePresentedLeaf(leafDer: leaf.der, parsedFacts: facts),
          platformTrust: leaf.platformTrust,
        ),
      );
    } catch (_) {
      _complete(
        CertificateProbeResult.failed(
          CertificateTrustFailure.malformedCertificate,
        ),
      );
    }
  }

  void _complete(CertificateProbeResult result) {
    if (!_outcome.isCompleted) _outcome.complete(result);
  }

  @override
  Future<CertificateProbeResult> get outcome => _outcome.future;

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _registration?.dispose();
    _complete(CertificateProbeResult.failed(CertificateTrustFailure.cancelled));
    final response = await _channel.invokeMethod(
      _cancelMethod,
      <String, Object?>{
        'protocolVersion': _protocolVersion,
        'operationId': operationId,
      },
    );
    if (!_cancelAcknowledged(response, operationId)) {
      throw StateError('Invalid cancel acknowledgement.');
    }
  }
}

sealed class _DecodedResponse {
  const _DecodedResponse();
}

final class _DecodedLeaf extends _DecodedResponse {
  const _DecodedLeaf(this.der, this.platformTrust);
  final Uint8List der;
  final PlatformTrust platformTrust;
}

final class _DecodedFailure extends _DecodedResponse {
  const _DecodedFailure(this.failure);
  final CertificateTrustFailure failure;
}

_DecodedResponse _decodeResponse(Object? response, String expectedOperationId) {
  if (response is! Map) {
    return const _DecodedFailure(CertificateTrustFailure.malformedCertificate);
  }
  final map = <String, Object?>{};
  for (final entry in response.entries) {
    if (entry.key is! String) {
      return const _DecodedFailure(
        CertificateTrustFailure.malformedCertificate,
      );
    }
    map[entry.key as String] = entry.value;
  }
  if (map['protocolVersion'] != _protocolVersion ||
      map['operationId'] != expectedOperationId) {
    return const _DecodedFailure(CertificateTrustFailure.malformedCertificate);
  }
  final hasLeaf = map.containsKey('leafDerBase64');
  final hasFailure = map.containsKey('failureCode');
  final expected = hasLeaf
      ? const {
          'protocolVersion',
          'operationId',
          'leafDerBase64',
          'platformTrust',
        }
      : const {'protocolVersion', 'operationId', 'failureCode'};
  if (hasLeaf == hasFailure ||
      map.keys.toSet().length != expected.length ||
      !map.keys.toSet().containsAll(expected)) {
    return const _DecodedFailure(CertificateTrustFailure.malformedCertificate);
  }
  if (hasFailure) {
    return switch (map['failureCode']) {
      'captureFailed' => const _DecodedFailure(
        CertificateTrustFailure.malformedCertificate,
      ),
      'cancelled' => const _DecodedFailure(CertificateTrustFailure.cancelled),
      _ => const _DecodedFailure(CertificateTrustFailure.malformedCertificate),
    };
  }
  final encoded = map['leafDerBase64'];
  final platformTrust = switch (map['platformTrust']) {
    'passed' => PlatformTrust.passed,
    'didNotPass' => PlatformTrust.didNotPass,
    _ => null,
  };
  if (encoded is! String ||
      platformTrust == null ||
      encoded.isEmpty ||
      encoded.length > ((_maximumDerBytes + 2) ~/ 3) * 4) {
    return const _DecodedFailure(CertificateTrustFailure.malformedCertificate);
  }
  try {
    final bytes = base64Decode(encoded);
    if (bytes.isEmpty ||
        bytes.length > _maximumDerBytes ||
        base64Encode(bytes) != encoded) {
      return const _DecodedFailure(
        CertificateTrustFailure.malformedCertificate,
      );
    }
    return _DecodedLeaf(Uint8List.fromList(bytes), platformTrust);
  } catch (_) {
    return const _DecodedFailure(CertificateTrustFailure.malformedCertificate);
  }
}

String _newOperationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
