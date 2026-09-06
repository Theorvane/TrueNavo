import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'certificate_facts.dart';
import 'der_x509_parser.dart';
import 'models.dart';
import 'native_tls_ports.dart';

export 'der_x509_parser.dart' show parsePresentedLeafDer;

const _protocolVersion = 1;
const _maximumDerBytes = 64 * 1024;
const _captureMethod = 'truedash.capturePresentedLeaf';
const _cancelMethod = 'truedash.cancelPresentedLeaf';

/// The deliberately tiny bridge used by the Apple capture adapter.
abstract interface class AppleTlsMethodChannel {
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments);
}

final class _FlutterAppleTlsMethodChannel implements AppleTlsMethodChannel {
  const _FlutterAppleTlsMethodChannel();
  static const _channel = MethodChannel('truedash.presented_leaf_probe.v1');

  @override
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments) =>
      _channel.invokeMethod<Object?>(method, arguments);
}

enum NativeTlsPlatform { apple, android, linux, windows, other }

NativeCertificateProbe createProbe() {
  final platform = Platform.isIOS || Platform.isMacOS
      ? NativeTlsPlatform.apple
      : NativeTlsPlatform.other;
  return createProbeForNativeTlsPlatform(platform);
}

NativeCertificateProbe createProbeForNativeTlsPlatform(
  NativeTlsPlatform platform, {
  AppleTlsMethodChannel? appleChannel,
  DateTime Function()? now,
}) {
  if (platform != NativeTlsPlatform.apple) return _UnavailableProbe();
  return BoundedNativeTlsPorts(
    backend: ApplePresentedLeafProbeBackend(
      channel: appleChannel ?? const _FlutterAppleTlsMethodChannel(),
      now: now ?? DateTime.now,
    ),
  );
}

PinnedRpcConnector createReconnect() => _UnavailableReconnect();

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

/// Apple-only, capture-only backend. It intentionally has no reconnect path.
final class ApplePresentedLeafProbeBackend implements NativeTlsAttemptBackend {
  ApplePresentedLeafProbeBackend({
    required this._channel,
    required DateTime Function() now,
  }) : _policy = CertificateFactsPolicy(now: now);

  final AppleTlsMethodChannel _channel;
  final CertificateFactsPolicy _policy;

  @override
  NativeProbeAttempt startProbe({
    required NormalizedAuthority authority,
    required CancellationToken cancellation,
  }) {
    final attempt = _AppleProbeAttempt(
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

final class _AppleProbeAttempt implements NativeProbeAttempt {
  _AppleProbeAttempt({
    required this.operationId,
    required this._channel,
    required this._policy,
    required this.authority,
    required this._cancellation,
  });

  final String operationId;
  final AppleTlsMethodChannel _channel;
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
    await _channel.invokeMethod(_cancelMethod, <String, Object?>{
      'protocolVersion': _protocolVersion,
      'operationId': operationId,
    });
  }
}

sealed class _DecodedResponse {
  const _DecodedResponse();
}

final class _DecodedLeaf extends _DecodedResponse {
  const _DecodedLeaf(this.der);
  final Uint8List der;
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
      ? const {'protocolVersion', 'operationId', 'leafDerBase64'}
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
  if (encoded is! String ||
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
    return _DecodedLeaf(Uint8List.fromList(bytes));
  } catch (_) {
    return const _DecodedFailure(CertificateTrustFailure.malformedCertificate);
  }
}

String _newOperationId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
