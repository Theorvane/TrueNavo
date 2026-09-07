import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/certificate_facts.dart';
import 'package:truedash/features/tls_trust/models.dart';
import 'package:truedash/features/tls_trust/native_tls_io.dart' as native_io;
import 'package:truedash/features/tls_trust/native_tls_ports.dart';
import 'package:truedash/features/tls_trust/native_tls_stub.dart'
    as native_stub;
import 'package:truedash/features/tls_trust/native_tls_web.dart' as native_web;
import 'package:truenas_api/truenas_api.dart';

void main() {
  final authority = NormalizedAuthority.parse('https://nas.example.test');
  final pin = PinRecord(
    leafDerSha256: 'A' * 64,
    createdAt: DateTime.utc(2026, 1, 1),
  );

  test('disposed cancellation registrations are not invoked', () {
    final source = CancellationSource();
    var disposedCalls = 0;
    var activeCalls = 0;
    final disposed = source.token.register(() => disposedCalls++);
    source.token.register(() => activeCalls++);

    disposed.dispose();
    disposed.dispose();
    source.cancel();
    source.cancel();

    expect(disposedCalls, 0);
    expect(activeCalls, 1);
  });

  group('bounded native TLS ports', () {
    test(
      'probe flattens an approvable policy result to display-safe facts',
      () async {
        final backend = ScriptedBackend()
          ..probeScript = CertificateProbeResult.approvable(
            _certificate(authority),
          );
        final outcome = await BoundedNativeTlsPorts(backend: backend).probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: CancellationSource().token,
        );
        expect(outcome, isA<NativeProbeCertificate>());
        expect(
          (outcome as NativeProbeCertificate).certificate.facts.leafDerSha256,
          'B' * 64,
        );
        expect(backend.events, ['probe', 'close probe']);
        _expectNoApplicationWork(backend);
      },
    );

    test('probe flattens certificate-policy failures rather than exposing a result', () async {
      final backend = ScriptedBackend()
        ..probeScript = CertificateProbeResult.failed(
          CertificateTrustFailure.hostnameMismatch,
        );
      final outcome = await BoundedNativeTlsPorts(backend: backend).probe(
        authority: authority,
        timeout: const Duration(seconds: 1),
        cancellation: CancellationSource().token,
      );
      expect(outcome, isA<NativeProbeFailure>());
      expect(
        (outcome as NativeProbeFailure).failure,
        CertificateTrustFailure.hostnameMismatch,
      );
      expect(backend.probeCloses, 1);
    });

    test('probe backend exception returns a typed boundary failure', () async {
      final backend = ScriptedBackend()..throwOnProbe = true;
      final outcome = await BoundedNativeTlsPorts(backend: backend).probe(
        authority: authority,
        timeout: const Duration(seconds: 1),
        cancellation: CancellationSource().token,
      );
      expect(
        outcome,
        const NativeProbeBoundaryFailure(
          NativeTlsBoundaryFailure.backendFailure,
        ),
      );
      expect(backend.probeCloses, 0);
      _expectNoApplicationWork(backend);
    });

    test('probe cleanup exception returns a typed boundary failure', () async {
      final backend = ScriptedBackend()..throwOnCloseProbe = true;
      final outcome = await BoundedNativeTlsPorts(backend: backend).probe(
        authority: authority,
        timeout: const Duration(seconds: 1),
        cancellation: CancellationSource().token,
      );
      expect(
        outcome,
        const NativeProbeBoundaryFailure(
          NativeTlsBoundaryFailure.cleanupFailed,
        ),
      );
      expect(backend.probeCloses, 1);
    });

    test(
      'probe rejects a valid certificate bound to another authority',
      () async {
        final otherAuthority = NormalizedAuthority.parse(
          'https://other.example.test',
        );
        final backend = ScriptedBackend()
          ..probeScript = CertificateProbeResult.approvable(
            _certificate(otherAuthority),
          );

        final outcome = await BoundedNativeTlsPorts(backend: backend).probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: CancellationSource().token,
        );

        expect(
          outcome,
          const NativeProbeFailure(
            CertificateTrustFailure.malformedCertificate,
          ),
        );
        expect(outcome, isNot(isA<NativeProbeCertificate>()));
        expect(backend.probeAuthorities, [authority]);
        expect(backend.probeCloses, 1);
        _expectNoApplicationWork(backend);
      },
    );

    test(
      'overlapping operations close each distinct attempt exactly once',
      () async {
        final backend = ScriptedBackend()..holdProbe = true;
        final ports = BoundedNativeTlsPorts(backend: backend);
        final first = ports.probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: CancellationSource().token,
        );
        final second = ports.probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: CancellationSource().token,
        );
        await Future<void>.delayed(Duration.zero);
        expect(backend.probeAttemptHandles, hasLength(2));
        expect(
          identical(
            backend.probeAttemptHandles[0],
            backend.probeAttemptHandles[1],
          ),
          isFalse,
        );
        backend.completeProbe(
          backend.probeAttemptHandles[0],
          CertificateProbeResult.approvable(_certificate(authority)),
        );
        await first;
        expect(backend.probeAttemptHandles[0].closed, isTrue);
        expect(backend.probeAttemptHandles[1].closed, isFalse);
        backend.completeProbe(
          backend.probeAttemptHandles[1],
          CertificateProbeResult.approvable(_certificate(authority)),
        );
        await second;
        expect(
          backend.closedProbeAttempts,
          orderedEquals(backend.probeAttemptHandles),
        );
        expect(
          backend.probeAttemptHandles.map((attempt) => attempt.closeCalls),
          [1, 1],
        );
        expect(backend.probeAttemptHandles[0].closed, isTrue);
        expect(backend.probeAttemptHandles[1].closed, isTrue);
      },
    );

    test(
      'cross-wired overlapping probes reject both certificates and close once',
      () async {
        final otherAuthority = NormalizedAuthority.parse(
          'https://other.example.test',
        );
        final backend = ScriptedBackend()..holdProbe = true;
        final ports = BoundedNativeTlsPorts(backend: backend);
        final first = ports.probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: CancellationSource().token,
        );
        final second = ports.probe(
          authority: otherAuthority,
          timeout: const Duration(seconds: 1),
          cancellation: CancellationSource().token,
        );

        await Future<void>.delayed(Duration.zero);
        backend.completeProbe(
          backend.probeAttemptHandles[0],
          CertificateProbeResult.approvable(_certificate(otherAuthority)),
        );
        backend.completeProbe(
          backend.probeAttemptHandles[1],
          CertificateProbeResult.approvable(_certificate(authority)),
        );

        expect(
          await first,
          const NativeProbeFailure(
            CertificateTrustFailure.malformedCertificate,
          ),
        );
        expect(
          await second,
          const NativeProbeFailure(
            CertificateTrustFailure.malformedCertificate,
          ),
        );
        expect(
          backend.probeAttemptHandles.map((attempt) => attempt.closeCalls),
          [1, 1],
        );
        expect(backend.probeAuthorities, [authority, otherAuthority]);
        _expectNoApplicationWork(backend);
      },
    );

    test('timeout and cancellation close the exact probe once; late completion is inert', () async {
      final timeoutBackend = ScriptedBackend()..holdProbe = true;
      final timedOut = await BoundedNativeTlsPorts(backend: timeoutBackend)
          .probe(
            authority: authority,
            timeout: const Duration(milliseconds: 1),
            cancellation: CancellationSource().token,
          );
      expect(
        timedOut,
        const NativeProbeFailure(CertificateTrustFailure.probeTimedOut),
      );
      expect(timeoutBackend.closedProbeAttempts, [
        timeoutBackend.probeAttemptHandles.single,
      ]);
      expect(timeoutBackend.probeAttemptHandles.single.outcomeSettled, isTrue);

      final source = CancellationSource();
      final cancelledBackend = ScriptedBackend()..holdProbe = true;
      final future = BoundedNativeTlsPorts(backend: cancelledBackend).probe(
        authority: authority,
        timeout: const Duration(seconds: 1),
        cancellation: source.token,
      );
      await Future<void>.delayed(Duration.zero);
      source.cancel();
      expect(
        await future,
        const NativeProbeFailure(CertificateTrustFailure.cancelled),
      );
      cancelledBackend.completeProbe(
        cancelledBackend.probeAttemptHandles.single,
        CertificateProbeResult.approvable(_certificate(authority)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cancelledBackend.probeCloses, 1);
      expect(
        cancelledBackend.probeAttemptHandles.single.outcomeSettled,
        isTrue,
      );
      _expectNoApplicationWork(cancelledBackend);
    });

    test(
      'timeout closes a deferred attempt before it can create a resource',
      () async {
        final backend = DeferredResourceBackend();
        final outcome = await BoundedNativeTlsPorts(backend: backend).probe(
          authority: authority,
          timeout: const Duration(milliseconds: 1),
          cancellation: CancellationSource().token,
        );

        expect(
          outcome,
          const NativeProbeFailure(CertificateTrustFailure.probeTimedOut),
        );
        expect(backend.attempt.closeCalls, 1);
        expect(backend.attempt.outcomeSettled, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(backend.resourceCreations, 0);
        expect(backend.attempt.closeCalls, 1);
      },
    );

    test('reconnect timeout closes a deferred attempt before it can create a resource', () async {
      final backend = DeferredResourceReconnectBackend();
      final outcome = await BoundedNativeTlsPorts(backend: backend).reconnect(
        authority: authority,
        pin: pin,
        timeout: const Duration(milliseconds: 1),
        cancellation: CancellationSource().token,
      );

      expect(
        outcome,
        const NativePinnedFailure(
          CertificateTrustFailure.pinnedReconnectFailed,
        ),
      );
      expect(backend.attempt.closeCalls, 1);
      expect(backend.attempt.outcomeSettled, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(backend.resourceCreations, 0);
      expect(backend.attempt.closeCalls, 1);
    });

    test(
      'cancellation during cleanup invalidates successful results',
      () async {
        final probeSource = CancellationSource();
        final probeBackend = ScriptedBackend()
          ..probeScript = CertificateProbeResult.approvable(
            _certificate(authority),
          )
          ..holdCloseProbe = true;
        final probeFuture = BoundedNativeTlsPorts(backend: probeBackend).probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: probeSource.token,
        );
        await probeBackend.probeCloseStarted.future;
        probeSource.cancel();
        probeBackend.releaseProbeClose();
        expect(
          await probeFuture,
          const NativeProbeFailure(CertificateTrustFailure.cancelled),
        );

        final reconnectSource = CancellationSource();
        final reconnectBackend = ScriptedBackend()
          ..reconnectScript = const NativePinnedVerified(_TestRpcTransport())
          ..holdCloseReconnect = true;
        final reconnectFuture = BoundedNativeTlsPorts(backend: reconnectBackend)
            .reconnect(
              authority: authority,
              pin: pin,
              timeout: const Duration(seconds: 1),
              cancellation: reconnectSource.token,
            );
        await reconnectBackend.reconnectCloseStarted.future;
        reconnectSource.cancel();
        reconnectBackend.releaseReconnectClose();
        expect(
          await reconnectFuture,
          const NativePinnedFailure(CertificateTrustFailure.cancelled),
        );
        _expectNoApplicationWork(probeBackend);
        _expectNoApplicationWork(reconnectBackend);
      },
    );

    test(
      'probe timeout remains authoritative while successful cleanup runs',
      () async {
        final backend = ScriptedBackend()
          ..probeScript = CertificateProbeResult.approvable(
            _certificate(authority),
          )
          ..holdCloseProbe = true;
        final future = BoundedNativeTlsPorts(backend: backend).probe(
          authority: authority,
          timeout: const Duration(milliseconds: 1),
          cancellation: CancellationSource().token,
        );

        await backend.probeCloseStarted.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        backend.releaseProbeClose();

        expect(
          await future,
          const NativeProbeFailure(CertificateTrustFailure.probeTimedOut),
        );
        expect(backend.probeCloses, 1);
        _expectNoApplicationWork(backend);
      },
    );

    test('pre-cancel and invalid probe timeout fail before activity', () async {
      final source = CancellationSource()..cancel();
      final backend = ScriptedBackend();
      final ports = BoundedNativeTlsPorts(backend: backend);
      expect(
        await ports.probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: source.token,
        ),
        const NativeProbeFailure(CertificateTrustFailure.cancelled),
      );
      expect(
        () => ports.probe(
          authority: authority,
          timeout: Duration.zero,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<NativeTlsArgumentError>()),
      );
      expect(backend.probeAttempts, 0);
      expect(backend.probeCloses, 0);
    });

    test('reconnect preserves certificate-policy rejection corpus', () async {
      for (final failure in [
        CertificateTrustFailure.pinMismatch,
        CertificateTrustFailure.hostnameMismatch,
        CertificateTrustFailure.expiredCertificate,
        CertificateTrustFailure.notYetValidCertificate,
        CertificateTrustFailure.malformedCertificate,
      ]) {
        final backend = ScriptedBackend()
          ..reconnectScript = NativePinnedFailure(failure);
        final outcome = await BoundedNativeTlsPorts(backend: backend).reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(seconds: 1),
          cancellation: CancellationSource().token,
        );
        expect(outcome, isA<NativePinnedFailure>());
        expect((outcome as NativePinnedFailure).failure, failure);
        expect(backend.reconnectCloses, 1);
        _expectNoApplicationWork(backend);
      }
    });

    test(
      'reconnect backend and cleanup exceptions are typed boundary failures',
      () async {
        final failing = ScriptedBackend()..throwOnReconnect = true;
        expect(
          await BoundedNativeTlsPorts(backend: failing).reconnect(
            authority: authority,
            pin: pin,
            timeout: const Duration(seconds: 1),
            cancellation: CancellationSource().token,
          ),
          const NativePinnedBoundaryFailure(
            NativeTlsBoundaryFailure.backendFailure,
          ),
        );
        final cleanup = ScriptedBackend()..throwOnCloseReconnect = true;
        expect(
          await BoundedNativeTlsPorts(backend: cleanup).reconnect(
            authority: authority,
            pin: pin,
            timeout: const Duration(seconds: 1),
            cancellation: CancellationSource().token,
          ),
          const NativePinnedBoundaryFailure(
            NativeTlsBoundaryFailure.cleanupFailed,
          ),
        );
      },
    );

    test('probe then reconnect creates distinct ordered attempts', () async {
      final backend = ScriptedBackend();
      final ports = BoundedNativeTlsPorts(backend: backend);
      await ports.probe(
        authority: authority,
        timeout: const Duration(seconds: 1),
        cancellation: CancellationSource().token,
      );
      await ports.reconnect(
        authority: authority,
        pin: pin,
        timeout: const Duration(seconds: 1),
        cancellation: CancellationSource().token,
      );
      expect(backend.events, [
        'probe',
        'close probe',
        'reconnect',
        'close reconnect',
      ]);
      expect(
        identical(
          backend.probeAttemptHandles.single,
          backend.reconnectAttemptHandles.single,
        ),
        isFalse,
      );
    });

    test('reconnect timeout, cancellation, pre-cancel, and invalid timeout are bounded', () async {
      final held = ScriptedBackend()..holdReconnect = true;
      final timedOut = await BoundedNativeTlsPorts(backend: held).reconnect(
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
      expect(held.closedReconnectAttempts, [
        held.reconnectAttemptHandles.single,
      ]);
      expect(held.reconnectAttemptHandles.single.outcomeSettled, isTrue);
      held.completeReconnect(
        held.reconnectAttemptHandles.single,
        const NativePinnedVerified(_TestRpcTransport()),
      );
      await Future<void>.delayed(Duration.zero);
      _expectNoApplicationWork(held);

      final source = CancellationSource();
      final cancelled = ScriptedBackend()..holdReconnect = true;
      final future = BoundedNativeTlsPorts(backend: cancelled).reconnect(
        authority: authority,
        pin: pin,
        timeout: const Duration(seconds: 1),
        cancellation: source.token,
      );
      await Future<void>.delayed(Duration.zero);
      source.cancel();
      expect(
        await future,
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
      cancelled.completeReconnect(
        cancelled.reconnectAttemptHandles.single,
        const NativePinnedVerified(_TestRpcTransport()),
      );
      await Future<void>.delayed(Duration.zero);
      _expectNoApplicationWork(cancelled);
      expect(cancelled.reconnectAttemptHandles.single.outcomeSettled, isTrue);

      final preCancelled = CancellationSource()..cancel();
      final untouched = ScriptedBackend();
      expect(
        await BoundedNativeTlsPorts(backend: untouched).reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(seconds: 1),
          cancellation: preCancelled.token,
        ),
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
      expect(
        () => BoundedNativeTlsPorts(backend: untouched).reconnect(
          authority: authority,
          pin: pin,
          timeout: Duration.zero,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<NativeTlsArgumentError>()),
      );
      expect(untouched.reconnectAttempts, 0);
    });

    test(
      'reconnect timeout remains authoritative while successful cleanup runs',
      () async {
        final backend = ScriptedBackend()
          ..reconnectScript = const NativePinnedVerified(_TestRpcTransport())
          ..holdCloseReconnect = true;
        final future = BoundedNativeTlsPorts(backend: backend).reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(milliseconds: 1),
          cancellation: CancellationSource().token,
        );

        await backend.reconnectCloseStarted.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        backend.releaseReconnectClose();

        expect(
          await future,
          const NativePinnedFailure(
            CertificateTrustFailure.pinnedReconnectFailed,
          ),
        );
        expect(backend.reconnectCloses, 1);
        _expectNoApplicationWork(backend);
      },
    );

    test(
      'reconnect disposes a staged transport when timeout wins during close',
      () async {
        final backend = OwnershipBackend()..holdClose = true;
        final reconnect = BoundedNativeTlsPorts(backend: backend).reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(milliseconds: 1),
          cancellation: CancellationSource().token,
        );

        await backend.closeStarted.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        backend.releaseClose();

        expect(
          await reconnect,
          const NativePinnedFailure(
            CertificateTrustFailure.pinnedReconnectFailed,
          ),
        );
        expect(backend.attempt.closeCalls, 1);
        expect(backend.attempt.transferCalls, 0);
        expect(backend.attempt.transport.closeCalls, 1);
      },
    );

    test(
      'reconnect disposes a staged transport when cancelled during close',
      () async {
        final source = CancellationSource();
        final backend = OwnershipBackend()..holdClose = true;
        final reconnect = BoundedNativeTlsPorts(backend: backend).reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(seconds: 1),
          cancellation: source.token,
        );

        await backend.closeStarted.future;
        source.cancel();
        backend.releaseClose();

        expect(
          await reconnect,
          const NativePinnedFailure(CertificateTrustFailure.cancelled),
        );
        expect(backend.attempt.closeCalls, 1);
        expect(backend.attempt.transferCalls, 0);
        expect(backend.attempt.transport.closeCalls, 1);
      },
    );

    test(
      'reconnect transfers its open transport once after close cleanup',
      () async {
        final backend = OwnershipBackend()..holdClose = true;
        final reconnect = BoundedNativeTlsPorts(backend: backend).reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(seconds: 1),
          cancellation: CancellationSource().token,
        );

        await backend.closeStarted.future;
        expect(backend.attempt.transferCalls, 0);
        backend.releaseClose();

        final outcome = await reconnect;
        expect(outcome, isA<NativePinnedVerified>());
        expect(
          (outcome as NativePinnedVerified).transport,
          same(backend.attempt.transport),
        );
        expect(backend.attempt.closeCalls, 1);
        expect(backend.attempt.transferCalls, 1);
        expect(backend.attempt.transport.closeCalls, 0);
      },
    );

    test('all platform modules provide their exact Task 4 result', () async {
      final token = CancellationSource().token;
      expect(
        await native_web.createProbe().probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: token,
        ),
        const NativeProbeBrowserManagedTls(),
      );
      expect(
        await native_web.createReconnect().reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(seconds: 1),
          cancellation: token,
        ),
        const NativePinnedBrowserManagedTls(),
      );
      // Do not exercise the real Flutter MethodChannel in a unit test. The
      // bridged runners are covered through their injected channels; all other
      // IO platforms are intentionally unavailable.
      for (final platform in <native_io.NativeTlsPlatform>[
        native_io.NativeTlsPlatform.linux,
        native_io.NativeTlsPlatform.windows,
        native_io.NativeTlsPlatform.other,
      ]) {
        expect(
          await native_io
              .createProbeForNativeTlsPlatform(platform)
              .probe(
                authority: authority,
                timeout: const Duration(seconds: 1),
                cancellation: token,
              ),
          const NativeProbeBoundaryFailure(
            NativeTlsBoundaryFailure.backendUnavailable,
          ),
          reason: platform.name,
        );
      }
      expect(
        await native_io
            .createReconnectForNativeTlsPlatform(
              native_io.NativeTlsPlatform.other,
            )
            .reconnect(
              authority: authority,
              pin: pin,
              timeout: const Duration(seconds: 1),
              cancellation: token,
            ),
        const NativePinnedBoundaryFailure(
          NativeTlsBoundaryFailure.backendUnavailable,
        ),
      );
      expect(
        await native_stub.createProbe().probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: token,
        ),
        const NativeProbeBoundaryFailure(
          NativeTlsBoundaryFailure.backendUnavailable,
        ),
      );
      expect(
        await native_stub.createReconnect().reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(seconds: 1),
          cancellation: token,
        ),
        const NativePinnedBoundaryFailure(
          NativeTlsBoundaryFailure.backendUnavailable,
        ),
      );
      final cancelled = CancellationSource()..cancel();
      expect(
        await native_web.createProbe().probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: cancelled.token,
        ),
        const NativeProbeFailure(CertificateTrustFailure.cancelled),
      );
      expect(
        await native_web.createReconnect().reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(seconds: 1),
          cancellation: cancelled.token,
        ),
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
      for (final platform in <native_io.NativeTlsPlatform>[
        native_io.NativeTlsPlatform.android,
        native_io.NativeTlsPlatform.linux,
        native_io.NativeTlsPlatform.windows,
        native_io.NativeTlsPlatform.other,
      ]) {
        expect(
          await native_io
              .createProbeForNativeTlsPlatform(platform)
              .probe(
                authority: authority,
                timeout: const Duration(seconds: 1),
                cancellation: cancelled.token,
              ),
          const NativeProbeFailure(CertificateTrustFailure.cancelled),
          reason: platform.name,
        );
      }
      expect(
        await native_io
            .createReconnectForNativeTlsPlatform(
              native_io.NativeTlsPlatform.other,
            )
            .reconnect(
              authority: authority,
              pin: pin,
              timeout: const Duration(seconds: 1),
              cancellation: cancelled.token,
            ),
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
      expect(
        await native_stub.createProbe().probe(
          authority: authority,
          timeout: const Duration(seconds: 1),
          cancellation: cancelled.token,
        ),
        const NativeProbeFailure(CertificateTrustFailure.cancelled),
      );
      expect(
        await native_stub.createReconnect().reconnect(
          authority: authority,
          pin: pin,
          timeout: const Duration(seconds: 1),
          cancellation: cancelled.token,
        ),
        const NativePinnedFailure(CertificateTrustFailure.cancelled),
      );
      expect(
        () => native_io
            .createProbeForNativeTlsPlatform(native_io.NativeTlsPlatform.other)
            .probe(
              authority: authority,
              timeout: Duration.zero,
              cancellation: token,
            ),
        throwsA(isA<NativeTlsArgumentError>()),
      );
      expect(
        () => native_io
            .createReconnectForNativeTlsPlatform(
              native_io.NativeTlsPlatform.other,
            )
            .reconnect(
              authority: authority,
              pin: pin,
              timeout: Duration.zero,
              cancellation: token,
            ),
        throwsA(isA<NativeTlsArgumentError>()),
      );
      expect(
        () => native_web.createProbe().probe(
          authority: authority,
          timeout: Duration.zero,
          cancellation: token,
        ),
        throwsA(isA<NativeTlsArgumentError>()),
      );
      expect(
        () => native_web.createReconnect().reconnect(
          authority: authority,
          pin: pin,
          timeout: Duration.zero,
          cancellation: token,
        ),
        throwsA(isA<NativeTlsArgumentError>()),
      );
      expect(
        () => native_stub.createProbe().probe(
          authority: authority,
          timeout: Duration.zero,
          cancellation: token,
        ),
        throwsA(isA<NativeTlsArgumentError>()),
      );
      expect(
        () => native_stub.createReconnect().reconnect(
          authority: authority,
          pin: pin,
          timeout: Duration.zero,
          cancellation: token,
        ),
        throwsA(isA<NativeTlsArgumentError>()),
      );
    });
  });

  test('Task 5 probe and Task 6 reconnect retain their separate capability boundaries', () {
    final root = Directory.current.path;
    final files = [
      'native_tls_ports.dart',
      'native_tls_stub.dart',
      'native_tls_io.dart',
      'native_tls_web.dart',
      'der_x509_parser.dart',
    ];
    final source = <String, String>{
      for (final file in files)
        file: File('$root/lib/features/tls_trust/$file').readAsStringSync(),
    };
    expect(source.values.where((text) => text.contains('dart:io')).length, 1);
    expect(source['native_tls_io.dart'], contains('dart:io'));
    expect(
      source['native_tls_web.dart'],
      contains('NativeProbeBrowserManagedTls'),
    );
    expect(
      source['native_tls_web.dart'],
      isNot(contains('CertificateProbeResult')),
    );
    expect(source['native_tls_web.dart'], isNot(contains('leafDerSha256')));
    expect(
      source['native_tls_ports.dart'],
      contains('NativeProbeAttempt startProbe'),
    );
    expect(
      source['native_tls_ports.dart'],
      contains('NativePinnedAttempt startReconnect'),
    );
    expect(
      source['native_tls_ports.dart'],
      isNot(contains('Future<NativeProbeAttempt>')),
    );
    expect(
      source['native_tls_ports.dart'],
      isNot(contains('Future<NativePinnedAttempt>')),
    );
    expect(source['native_tls_ports.dart'], isNot(contains('finalizeProbe')));
    expect(
      source['native_tls_ports.dart'],
      isNot(contains('finalizeReconnect')),
    );
    expect(
      source['native_tls_ports.dart'],
      isNot(contains('NativeTlsOperationToken')),
    );
    expect(source['native_tls_ports.dart'], isNot(contains('Future.any')));
    expect(source['native_tls_ports.dart'], isNot(contains('Future.delayed')));
    expect(source['native_tls_ports.dart'], isNot(contains('whenCancelled')));
    expect(source['native_tls_ports.dart'], contains('Timer('));
    expect(source['native_tls_ports.dart'], contains('timer.cancel()'));
    expect(source['native_tls_ports.dart'], contains('registration.dispose()'));
    expect(
      source['native_tls_ports.dart'],
      isNot(contains('NativeProbeCertificate(this.result)')),
    );
    expect(source['native_tls_ports.dart'], contains('certificate != null'));
    expect(source['native_tls_ports.dart'], contains('failure == null'));
    expect(source['native_tls_web.dart'], isNot(contains('certificate')));
    expect(source['native_tls_web.dart'], isNot(contains('fingerprint')));
    expect(source['native_tls_web.dart'], isNot(contains('approve')));
    for (final entry in source.entries) {
      final text = entry.value;
      for (final forbidden in [
        'badCertificateCallback',
        'allowBadCertificates',
        'trustAll',
        'SecurityContext',
        'SecureSocket',
        'HttpClient',
        'PinStore',
        'dynamic',
      ]) {
        expect(text.contains(forbidden), isFalse);
      }
      if (entry.key == 'native_tls_io.dart') {
        // Task 6 has one deliberately narrow exception: its Apple-only
        // reconnect adapter implements RpcTransport.  The probe surface
        // below remains free of pins and application/auth payloads.
        expect(text, contains("package:truenas_api/truenas_api.dart"));
        expect(text, contains('PinnedRpcChannel'));
        expect(text, contains('Future<Object?> invokeMethod'));
        expect(text, contains("'truedash.capturePresentedLeaf'"));
        expect(text, contains("'truedash.cancelPresentedLeaf'"));
        expect(text, contains("'protocolVersion'"));
        expect(text, contains("'operationId'"));
        expect(text, contains("'host'"));
        expect(text, contains("'port'"));
        final probeAttempt = text.substring(
          text.indexOf('final class _ProbeAttempt'),
          text.indexOf('void _onResponse'),
        );
        final probeInvoke = probeAttempt.substring(
          probeAttempt.indexOf('response = _channel.invokeMethod'),
          probeAttempt.indexOf('response.then('),
        );
        for (final forbiddenBridgeTerm in [
          'credential',
          'apiKey',
          'pin',
          'header',
          'body',
          'applicationData',
          'frame',
        ]) {
          expect(probeInvoke.contains(forbiddenBridgeTerm), isFalse);
        }
        expect(RegExp(r'\bObject(?!\?)').hasMatch(text), isFalse);
      } else {
        expect(text.contains('Object'), isFalse);
      }
      if (entry.key != 'native_tls_io.dart') {
        expect(
          RegExp(r'Future<[^>]+>\s+\w+\([^)]*\bObject\b').hasMatch(text),
          isFalse,
        );
      }
    }
  });

  test('normal public trust remains on the platform TLS connector', () {
    final appConnector = File(
      'lib/features/connection/connection_controller.dart',
    ).readAsStringSync();
    final normalConnector = File(
      '../../packages/truenas_api/lib/src/transport/web_socket_connector.dart',
    ).readAsStringSync();

    expect(appConnector, contains('const WebSocketRpcConnector()'));
    expect(normalConnector, contains("platform's normal TLS policy"));
    expect(normalConnector, contains('WebSocketChannel.connect(endpoint)'));
    for (final forbidden in [
      'badCertificateCallback',
      'allowBadCertificates',
      'trustAll',
      'SecurityContext',
    ]) {
      expect(normalConnector, isNot(contains(forbidden)));
    }
  });
}

void _expectNoApplicationWork(ScriptedBackend backend) {
  expect([backend.upgrades, backend.frames, backend.apiKeyHandoffs], [0, 0, 0]);
}

PresentedCertificate _certificate(NormalizedAuthority authority) =>
    PresentedCertificate(
      authority: authority,
      facts: CertificateFacts(
        subjectSummary: 'DNS: nas.example.test',
        issuerSummary: 'Example CA',
        leafDerSha256: 'B' * 64,
        notValidBefore: DateTime.utc(2025),
        notValidAfter: DateTime.utc(2027),
      ),
    );

final class ScriptedBackend implements NativeTlsAttemptBackend {
  CertificateProbeResult probeScript = CertificateProbeResult.failed(
    CertificateTrustFailure.malformedCertificate,
  );
  NativePinnedOutcome reconnectScript = const NativePinnedFailure(
    CertificateTrustFailure.pinnedReconnectFailed,
  );
  bool throwOnProbe = false,
      throwOnReconnect = false,
      throwOnCloseProbe = false,
      throwOnCloseReconnect = false,
      holdProbe = false,
      holdReconnect = false,
      holdCloseProbe = false,
      holdCloseReconnect = false;
  int probeAttempts = 0,
      reconnectAttempts = 0,
      probeCloses = 0,
      reconnectCloses = 0;
  int upgrades = 0, frames = 0, apiKeyHandoffs = 0;
  final events = <String>[];
  final probeAuthorities = <NormalizedAuthority>[];
  final probeAttemptHandles = <ScriptedProbeAttempt>[];
  final reconnectAttemptHandles = <ScriptedPinnedAttempt>[];
  final closedProbeAttempts = <ScriptedProbeAttempt>[];
  final closedReconnectAttempts = <ScriptedPinnedAttempt>[];
  final probeCloseStarted = Completer<void>();
  final reconnectCloseStarted = Completer<void>();
  final _probeCloseRelease = Completer<void>();
  final _reconnectCloseRelease = Completer<void>();

  @override
  NativeProbeAttempt startProbe({
    required NormalizedAuthority authority,
    required CancellationToken cancellation,
  }) {
    probeAttempts++;
    probeAuthorities.add(authority);
    events.add('probe');
    if (throwOnProbe) throw StateError('scripted');
    final attempt = ScriptedProbeAttempt(this);
    probeAttemptHandles.add(attempt);
    if (!holdProbe) attempt.complete(probeScript);
    return attempt;
  }

  void completeProbe(
    ScriptedProbeAttempt attempt,
    CertificateProbeResult value,
  ) => attempt.complete(value);

  @override
  NativePinnedAttempt startReconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required CancellationToken cancellation,
  }) {
    reconnectAttempts++;
    events.add('reconnect');
    if (throwOnReconnect) throw StateError('scripted');
    final attempt = ScriptedPinnedAttempt(this);
    reconnectAttemptHandles.add(attempt);
    if (!holdReconnect) attempt.complete(reconnectScript);
    return attempt;
  }

  void completeReconnect(
    ScriptedPinnedAttempt attempt,
    NativePinnedOutcome value,
  ) => attempt.complete(value);

  Future<void> closeProbe(ScriptedProbeAttempt attempt) async {
    probeCloses++;
    events.add('close probe');
    closedProbeAttempts.add(attempt);
    if (!probeCloseStarted.isCompleted) probeCloseStarted.complete();
    if (holdCloseProbe) await _probeCloseRelease.future;
    if (throwOnCloseProbe) throw StateError('cleanup');
  }

  void releaseProbeClose() {
    if (!_probeCloseRelease.isCompleted) _probeCloseRelease.complete();
  }

  Future<void> closeReconnect(ScriptedPinnedAttempt attempt) async {
    reconnectCloses++;
    events.add('close reconnect');
    closedReconnectAttempts.add(attempt);
    if (!reconnectCloseStarted.isCompleted) {
      reconnectCloseStarted.complete();
    }
    if (holdCloseReconnect) await _reconnectCloseRelease.future;
    if (throwOnCloseReconnect) throw StateError('cleanup');
  }

  void releaseReconnectClose() {
    if (!_reconnectCloseRelease.isCompleted) {
      _reconnectCloseRelease.complete();
    }
  }
}

final class DeferredResourceBackend implements NativeTlsAttemptBackend {
  late final DeferredResourceProbeAttempt attempt;
  int resourceCreations = 0;

  @override
  NativeProbeAttempt startProbe({
    required NormalizedAuthority authority,
    required CancellationToken cancellation,
  }) {
    attempt = DeferredResourceProbeAttempt(this);
    Future<void>.delayed(const Duration(milliseconds: 20), attempt.start);
    return attempt;
  }

  @override
  NativePinnedAttempt startReconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required CancellationToken cancellation,
  }) => throw UnimplementedError();
}

final class DeferredResourceProbeAttempt implements NativeProbeAttempt {
  DeferredResourceProbeAttempt(this._backend);

  final DeferredResourceBackend _backend;
  final _outcome = Completer<CertificateProbeResult>();
  bool _closed = false;
  int closeCalls = 0;

  bool get outcomeSettled => _outcome.isCompleted;

  @override
  Future<CertificateProbeResult> get outcome => _outcome.future;

  void start() {
    if (_closed) return;
    _backend.resourceCreations++;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCalls++;
    if (!_outcome.isCompleted) {
      _outcome.complete(
        CertificateProbeResult.failed(
          CertificateTrustFailure.malformedCertificate,
        ),
      );
    }
  }
}

final class DeferredResourceReconnectBackend
    implements NativeTlsAttemptBackend {
  late final DeferredResourcePinnedAttempt attempt;
  int resourceCreations = 0;

  @override
  NativeProbeAttempt startProbe({
    required NormalizedAuthority authority,
    required CancellationToken cancellation,
  }) => throw UnimplementedError();

  @override
  NativePinnedAttempt startReconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required CancellationToken cancellation,
  }) {
    attempt = DeferredResourcePinnedAttempt(this);
    Future<void>.delayed(const Duration(milliseconds: 20), attempt.start);
    return attempt;
  }
}

final class DeferredResourcePinnedAttempt implements NativePinnedAttempt {
  DeferredResourcePinnedAttempt(this._backend);

  final DeferredResourceReconnectBackend _backend;
  final _outcome = Completer<NativePinnedOutcome>();
  bool _closed = false;
  int closeCalls = 0;

  bool get outcomeSettled => _outcome.isCompleted;

  @override
  Future<NativePinnedOutcome> get outcome => _outcome.future;

  void start() {
    if (_closed) return;
    _backend.resourceCreations++;
  }

  @override
  void transferTransport() {}

  @override
  Future<void> discardTransport() => close();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCalls++;
    if (!_outcome.isCompleted) {
      _outcome.complete(
        const NativePinnedFailure(
          CertificateTrustFailure.pinnedReconnectFailed,
        ),
      );
    }
  }
}

final class ScriptedProbeAttempt implements NativeProbeAttempt {
  ScriptedProbeAttempt(this._backend);

  final ScriptedBackend _backend;
  final _outcome = Completer<CertificateProbeResult>();
  bool closed = false;
  int closeCalls = 0;

  bool get outcomeSettled => _outcome.isCompleted;

  @override
  Future<CertificateProbeResult> get outcome => _outcome.future;

  void complete(CertificateProbeResult value) {
    if (!_outcome.isCompleted) _outcome.complete(value);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    closeCalls++;
    if (!_outcome.isCompleted) {
      _outcome.complete(
        CertificateProbeResult.failed(
          CertificateTrustFailure.malformedCertificate,
        ),
      );
    }
    await _backend.closeProbe(this);
  }
}

final class _TestRpcTransport implements RpcTransport {
  const _TestRpcTransport();

  @override
  Stream<String> get inboundFrames => const Stream.empty();

  @override
  Future<void> close() async {}

  @override
  Future<void> send(String frame) async {}
}

final class ScriptedPinnedAttempt implements NativePinnedAttempt {
  ScriptedPinnedAttempt(this._backend);

  final ScriptedBackend _backend;
  final _outcome = Completer<NativePinnedOutcome>();
  bool closed = false;
  int closeCalls = 0;

  bool get outcomeSettled => _outcome.isCompleted;

  @override
  Future<NativePinnedOutcome> get outcome => _outcome.future;

  @override
  void transferTransport() {}

  @override
  Future<void> discardTransport() => close();

  void complete(NativePinnedOutcome value) {
    if (!_outcome.isCompleted) _outcome.complete(value);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    closeCalls++;
    if (!_outcome.isCompleted) {
      _outcome.complete(
        const NativePinnedFailure(
          CertificateTrustFailure.pinnedReconnectFailed,
        ),
      );
    }
    await _backend.closeReconnect(this);
  }
}

final class OwnershipBackend implements NativeTlsAttemptBackend {
  late final OwnershipPinnedAttempt attempt;
  bool holdClose = false;
  final closeStarted = Completer<void>();
  final _closeRelease = Completer<void>();

  @override
  NativeProbeAttempt startProbe({
    required NormalizedAuthority authority,
    required CancellationToken cancellation,
  }) => throw UnimplementedError();

  @override
  NativePinnedAttempt startReconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required CancellationToken cancellation,
  }) => attempt = OwnershipPinnedAttempt(this);

  void releaseClose() {
    if (!_closeRelease.isCompleted) _closeRelease.complete();
  }
}

final class OwnershipPinnedAttempt implements NativePinnedAttempt {
  OwnershipPinnedAttempt(this._backend) {
    _outcome.complete(NativePinnedVerified(transport));
  }

  final OwnershipBackend _backend;
  final transport = _TrackingRpcTransport();
  final _outcome = Completer<NativePinnedOutcome>();
  int closeCalls = 0;
  int transferCalls = 0;
  Future<void>? _closeFuture;
  Future<void>? _discardFuture;

  @override
  Future<NativePinnedOutcome> get outcome => _outcome.future;

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    closeCalls++;
    if (!_backend.closeStarted.isCompleted) _backend.closeStarted.complete();
    if (_backend.holdClose) await _backend._closeRelease.future;
  }

  @override
  Future<void> discardTransport() => _discardFuture ??= transport.close();

  @override
  void transferTransport() => transferCalls++;
}

final class _TrackingRpcTransport implements RpcTransport {
  int closeCalls = 0;

  @override
  Stream<String> get inboundFrames => const Stream.empty();

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<void> send(String frame) async {}
}
