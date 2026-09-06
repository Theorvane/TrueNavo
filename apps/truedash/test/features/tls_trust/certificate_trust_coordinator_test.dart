import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/certificate_facts.dart';
import 'package:truedash/features/tls_trust/certificate_trust_coordinator.dart';
import 'package:truedash/features/tls_trust/models.dart';
import 'package:truedash/features/tls_trust/native_tls_ports.dart';
import 'package:truedash/features/tls_trust/pin_store.dart';
import 'package:truedash/features/tls_trust/raw_pin_storage.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  final authority = NormalizedAuthority.parse('https://nas.example.test');
  final digest = 'A' * 64;
  final facts = CertificateFacts(
    subjectSummary: 'NAS',
    issuerSummary: 'NAS CA',
    leafDerSha256: digest,
    notValidBefore: DateTime.utc(2026),
    notValidAfter: DateTime.utc(2027),
  );

  test(
    'no pin probes before review and approval stages, reconnects, then commits',
    () async {
      final events = <String>[];
      final store = _Store(events);
      final probe = _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      );
      final connector = _Connector(events);
      final transport = _Transport();
      connector.outcome = NativePinnedVerified(transport);
      final coordinator = CertificateTrustCoordinator(
        pinStore: store,
        probe: probe,
        connector: connector,
        now: () => DateTime.utc(2026, 1, 2, 3, 4, 5, 6),
        probeTimeout: const Duration(seconds: 1),
        reconnectTimeout: const Duration(seconds: 1),
      );

      final review = await coordinator.begin(authority);
      expect(review, isA<FirstTrustReview>());
      final token = (review as FirstTrustReview).token;
      expect(events, ['recover', 'read', 'probe', 'read']);

      final verified = await coordinator.approve(token);
      expect(verified, isA<VerifiedTrustTransport>());
      expect((verified as VerifiedTrustTransport).transport, same(transport));
      expect(events, [
        'recover',
        'read',
        'probe',
        'read',
        'read',
        'stage',
        'read',
        'reconnect',
        'read',
        'commit',
      ]);
      expect(connector.pin!.leafDerSha256, digest);
    },
  );

  test('stored pin reconnects directly and never probes or writes', () async {
    final events = <String>[];
    final pin = PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026));
    final store = _Store(events)..readResult = PinReadResult.record(pin);
    final probe = _Probe(
      events,
      const NativeProbeFailure(CertificateTrustFailure.malformedCertificate),
    );
    final connector = _Connector(events)
      ..outcome = NativePinnedVerified(_Transport());
    final coordinator = _coordinator(store, probe, connector);

    expect(await coordinator.begin(authority), isA<VerifiedTrustTransport>());
    expect(events, ['recover', 'read', 'read', 'reconnect', 'read']);
  });

  test('replacement review keeps the active record until verified reconnect commits', () async {
    final events = <String>[];
    final old = PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026));
    final newFacts = CertificateFacts(
      subjectSummary: 'NAS replacement',
      issuerSummary: 'New CA',
      leafDerSha256: 'B' * 64,
      notValidBefore: DateTime.utc(2026),
      notValidAfter: DateTime.utc(2027),
    );
    final store = _Store(events)..readResult = PinReadResult.record(old);
    final probe = _Probe(
      events,
      NativeProbeCertificate(
        PresentedCertificate(authority: authority, facts: newFacts),
      ),
    );
    final connector = _Connector(events)
      ..outcome = NativePinnedVerified(_Transport());
    final coordinator = _coordinator(store, probe, connector);

    final review = await coordinator.checkForReplacement(
      authority,
    ) as ReplacementTrustReview;
    expect(store.active, same(old));
    expect(events, ['recover', 'read', 'probe', 'read']);
    await coordinator.approve(review.token);
    expect(events, [
      'recover',
      'read',
      'probe',
      'read',
      'read',
      'stage',
      'read',
      'reconnect',
      'read',
      'commit',
    ]);
    expect(store.active!.leafDerSha256, 'B' * 64);
  });

  test('cancelled late reconnect is discarded and never handed off', () async {
    final events = <String>[];
    final store = _Store(events);
    final probe = _Probe(
      events,
      NativeProbeCertificate(
        PresentedCertificate(authority: authority, facts: facts),
      ),
    );
    final connector = _Connector(events)
      ..wait = Completer<NativePinnedOutcome>();
    final coordinator = _coordinator(store, probe, connector);
    final review = await coordinator.begin(authority) as FirstTrustReview;
    final approval = coordinator.approve(review.token);
    await Future<void>.delayed(Duration.zero);
    final cancelled = coordinator.cancel(review.token);
    final transport = _Transport();
    connector.wait!.complete(NativePinnedVerified(transport));
    expect(
      await cancelled,
      _blocked(CertificateTrustCoordinatorFailure.cancelled),
    );
    expect(
      await approval,
      _blocked(CertificateTrustCoordinatorFailure.cancelled),
    );
    expect(transport.closeCount, 1);
    expect(store.lastTransaction!.abortCount, 1);
    expect(store.commitCount, 0);
  });

  test(
    'store, policy, boundary, and browser outcomes are typed and safe',
    () async {
      final events = <String>[];
      final failedStore = _Store(events)
        ..readResult = const PinReadFailure(PinStoreFailure.readFailed);
      final noProbe = _Probe(
        events,
        const NativeProbeFailure(CertificateTrustFailure.malformedCertificate),
      );
      expect(
        await _coordinator(
          failedStore,
          noProbe,
          _Connector(events),
        ).begin(authority),
        _blocked(CertificateTrustCoordinatorFailure.pinStore),
      );
      expect(events, ['recover', 'read']);

      final browserEvents = <String>[];
      final browser = _coordinator(
        _Store(browserEvents),
        _Probe(browserEvents, const NativeProbeBrowserManagedTls()),
        _Connector(browserEvents),
      );
      expect(await browser.begin(authority), isA<BrowserManagedTrust>());

      final reconnectEvents = <String>[];
      final pinned = PinRecord(
        leafDerSha256: digest,
        createdAt: DateTime.utc(2026),
      );
      final reconnect = _coordinator(
        _Store(reconnectEvents)..readResult = PinReadResult.record(pinned),
        _Probe(reconnectEvents, const NativeProbeBrowserManagedTls()),
        _Connector(reconnectEvents)
          ..outcome = const NativePinnedBoundaryFailure(
            NativeTlsBoundaryFailure.backendFailure,
          ),
      );
      expect(
        await reconnect.begin(authority),
        _blocked(CertificateTrustCoordinatorFailure.nativeBoundary),
      );
      expect(reconnectEvents, ['recover', 'read', 'read', 'reconnect']);
    },
  );

  test('same authority joins one operation while distinct authorities are independent', () async {
    final events = <String>[];
    final first = NormalizedAuthority.parse('https://one.example.test');
    final second = NormalizedAuthority.parse('https://two.example.test');
    final firstFacts = CertificateFacts(
      subjectSummary: 'one',
      issuerSummary: 'CA',
      leafDerSha256: '1' * 64,
      notValidBefore: DateTime.utc(2026),
      notValidAfter: DateTime.utc(2027),
    );
    final secondFacts = CertificateFacts(
      subjectSummary: 'two',
      issuerSummary: 'CA',
      leafDerSha256: '2' * 64,
      notValidBefore: DateTime.utc(2026),
      notValidAfter: DateTime.utc(2027),
    );
    final probe =
        _Probe(
            events,
            NativeProbeCertificate(
              PresentedCertificate(authority: first, facts: firstFacts),
            ),
          )
          ..byAuthority = {
            first: NativeProbeCertificate(
              PresentedCertificate(authority: first, facts: firstFacts),
            ),
            second: NativeProbeCertificate(
              PresentedCertificate(authority: second, facts: secondFacts),
            ),
          };
    final coordinator = _coordinator(_Store(events), probe, _Connector(events));
    final firstAttempt = coordinator.start(first);
    final joined = coordinator.start(first);
    expect(joined.token, same(firstAttempt.token));
    expect(joined.state, same(firstAttempt.state));
    final other = coordinator.start(second);
    expect(other.token, isNot(same(firstAttempt.token)));
    final states = await Future.wait([firstAttempt.state, other.state]);
    expect(states, everyElement(isA<FirstTrustReview>()));
    expect(events.where((event) => event == 'probe'), hasLength(2));
  });

  test('different authorities complete independently with authority-correct transports', () async {
    final events = <String>[];
    final first = NormalizedAuthority.parse('https://one.example.test');
    final second = NormalizedAuthority.parse('https://two.example.test');
    final pin = PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026));
    final firstWait = Completer<NativePinnedOutcome>();
    final secondWait = Completer<NativePinnedOutcome>();
    final connector = _Connector(events)
      ..waitsByAuthority = {first: firstWait, second: secondWait};
    final coordinator = _coordinator(
      _Store(events)..active = pin,
      _Probe(events, const NativeProbeBrowserManagedTls()),
      connector,
    );

    final firstPending = coordinator.begin(first);
    final secondPending = coordinator.begin(second);
    await Future<void>.delayed(Duration.zero);
    final firstTransport = _Transport();
    final secondTransport = _Transport();
    secondWait.complete(NativePinnedVerified(secondTransport));
    final secondState = await secondPending as VerifiedTrustTransport;
    expect(secondState.transport, same(secondTransport));
    expect(firstWait.isCompleted, isFalse);
    firstWait.complete(NativePinnedVerified(firstTransport));
    final firstState = await firstPending as VerifiedTrustTransport;
    expect(firstState.transport, same(firstTransport));
    expect(firstTransport.closeCount, 0);
    expect(secondTransport.closeCount, 0);
  });

  test('read and stage exceptions are typed pin-store failures', () async {
    final readStore = _Store([])..throwRead = true;
    expect(
      await _coordinator(
        readStore,
        _Probe([], const NativeProbeBrowserManagedTls()),
        _Connector([]),
      ).begin(authority),
      _blocked(CertificateTrustCoordinatorFailure.pinStore),
    );
    final store = _Store([])..throwStage = true;
    final stagingCoordinator = _coordinator(
      store,
      _Probe(
        [],
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      ),
      _Connector([]),
    );
    final review =
        await stagingCoordinator.begin(authority) as FirstTrustReview;
    expect(
      await stagingCoordinator.approve(review.token),
      _blocked(CertificateTrustCoordinatorFailure.pinStore),
    );
  });

  test(
    'cancellation while stage or reconnect cleans up exactly once',
    () async {
      final events = <String>[];
      final store = _Store(events)..stageWait = Completer<PinStageResult>();
      final coordinator = _coordinator(
        store,
        _Probe(
          events,
          NativeProbeCertificate(
            PresentedCertificate(authority: authority, facts: facts),
          ),
        ),
        _Connector(events),
      );
      final review = await coordinator.begin(authority) as FirstTrustReview;
      final approval = coordinator.approve(review.token);
      await Future<void>.delayed(Duration.zero);
      final cancelled = coordinator.cancel(review.token);
      final tx = _Transaction(
        store,
        PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026)),
      );
      store.stageWait!.complete(PinStageSuccess(tx));
      expect(
        await cancelled,
        _blocked(CertificateTrustCoordinatorFailure.cancelled),
      );
      expect(
        await approval,
        _blocked(CertificateTrustCoordinatorFailure.cancelled),
      );
      expect(tx.abortCount, 1);
    },
  );

  test(
    'cancel during initial read is final and a late read is inert',
    () async {
      final events = <String>[];
      final store = _Store(events)
        ..readWait = Completer<PinReadResult>()
        ..readStarted = Completer<void>();
      final coordinator = _coordinator(
        store,
        _Probe(events, const NativeProbeBrowserManagedTls()),
        _Connector(events),
      );
      final handle = coordinator.start(authority);
      await store.readStarted!.future;
      final cancelled = coordinator.cancel(handle.token);
      store.readWait!.complete(const PinAbsent());
      expect(
        await cancelled,
        _blocked(CertificateTrustCoordinatorFailure.cancelled),
      );
      expect(
        await handle.state,
        _blocked(CertificateTrustCoordinatorFailure.cancelled),
      );
      expect(events, ['recover', 'read']);
    },
  );

  test('commit failure closes verified transport and never aborts', () async {
    final events = <String>[];
    final store = _Store(events)
      ..transactionCommit = const PinStoreResult.failure(
        PinStoreFailure.writeFailed,
      );
    final transport = _Transport();
    final connector = _Connector(events)
      ..outcome = NativePinnedVerified(transport);
    final coordinator = _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      ),
      connector,
    );
    final review = await coordinator.begin(authority) as FirstTrustReview;
    expect(
      await coordinator.approve(review.token),
      _blocked(CertificateTrustCoordinatorFailure.pinStore),
    );
    expect(transport.closeCount, 1);
    expect(store.lastTransaction!.abortCount, 0);
    expect(
      store.active,
      isNull,
      reason: 'a pre-write commit failure preserves active',
    );
  });

  test('cancel during commit waits for successful durable handoff', () async {
    final events = <String>[];
    final store = _Store(events)..commitWait = Completer<PinStoreResult>();
    final transport = _Transport();
    final coordinator = _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      ),
      _Connector(events)..outcome = NativePinnedVerified(transport),
    );
    final review = await coordinator.begin(authority) as FirstTrustReview;
    final approval = coordinator.approve(review.token);
    await Future<void>.delayed(Duration.zero);
    final cancelled = coordinator.cancel(review.token);
    store.commitWait!.complete(const PinStoreSuccess());
    expect(await cancelled, isA<VerifiedTrustTransport>());
    expect(await approval, isA<VerifiedTrustTransport>());
    expect(transport.closeCount, 0);
  });

  test('wrong authority replacement probe fails closed and terminal starts are fresh', () async {
    final events = <String>[];
    final old = PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026));
    final store = _Store(events)..readResult = PinReadResult.record(old);
    final wrong = NormalizedAuthority.parse('https://wrong.example.test');
    final coordinator = _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: wrong, facts: facts),
        ),
      ),
      _Connector(events),
    );
    expect(
      await coordinator.checkForReplacement(authority),
      _blocked(CertificateTrustCoordinatorFailure.malformedCertificate),
    );
    final fresh = coordinator.start(authority);
    expect(fresh.token, isNotNull);
    expect(
      await fresh.state,
      _blocked(CertificateTrustCoordinatorFailure.nativeBoundary),
    );
    expect(events.where((event) => event == 'read'), hasLength(3));
  });

  test('approval rejects an active pin that appears after staging', () async {
    final events = <String>[];
    final competing = PinRecord(
      leafDerSha256: 'C' * 64,
      createdAt: DateTime.utc(2026, 2),
    );
    final store = _Store(events);
    store.onStage = () => store.active = competing;
    final coordinator = _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      ),
      _Connector(events)..outcome = NativePinnedVerified(_Transport()),
    );
    final review = await coordinator.begin(authority) as FirstTrustReview;
    expect(
      await coordinator.approve(review.token),
      _blocked(CertificateTrustCoordinatorFailure.candidateChanged),
    );
    expect(store.active, same(competing));
    expect(store.lastTransaction!.abortCount, 1);
    expect(events.where((event) => event == 'reconnect'), isEmpty);
  });

  test('recovery aborts an orphan before a fresh read, and abort failure is cleanup', () async {
    final events = <String>[];
    final orphan = _Transaction(
      _Store(events),
      PinRecord(leafDerSha256: 'C' * 64, createdAt: DateTime.utc(2026)),
    );
    final store = orphan.store
      ..recoveryResult = PinRecoverySuccess(orphan.replacement, orphan)
      ..readResult = const PinAbsent();
    final state = await _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      ),
      _Connector(events),
    ).begin(authority);
    expect(state, isA<FirstTrustReview>());
    expect(events, ['recover', 'read', 'probe', 'read']);
    expect(orphan.abortCount, 1);
  });

  test('approval connector throw is native-boundary and aborts once', () async {
    final events = <String>[];
    final connector = _Connector(events)..throwReconnect = true;
    final coordinator = _coordinator(
      _Store(events),
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      ),
      connector,
    );
    final review = await coordinator.begin(authority) as FirstTrustReview;
    expect(
      await coordinator.approve(review.token),
      _blocked(CertificateTrustCoordinatorFailure.nativeBoundary),
    );
    expect(events.where((event) => event == 'reconnect'), hasLength(1));
  });

  for (final failure in CertificateTrustFailure.values) {
    test(
      'probe policy $failure is mapped without leaking boundary details',
      () async {
        final state = await _coordinator(
          _Store([]),
          _Probe([], NativeProbeFailure(failure)),
          _Connector([]),
        ).begin(authority);
        expect(state, _blocked(_expectedFailure(failure)));
        expect(state.toString(), isNot(contains('DER')));
        expect(state.toString(), isNot(contains('credential')));
      },
    );
    test('reconnect policy $failure is mapped', () async {
      final pin = PinRecord(
        leafDerSha256: digest,
        createdAt: DateTime.utc(2026),
      );
      final state = await _coordinator(
        _Store([])..readResult = PinReadResult.record(pin),
        _Probe(
          [],
          failure == CertificateTrustFailure.pinMismatch
              ? const NativeProbeFailure(CertificateTrustFailure.pinMismatch)
              : const NativeProbeBrowserManagedTls(),
        ),
        _Connector([])..outcome = NativePinnedFailure(failure),
      ).begin(authority);
      expect(state, _blocked(_expectedFailure(failure)));
    });
  }

  for (final boundary in NativeTlsBoundaryFailure.values) {
    test(
      'native boundary $boundary maps consistently for probe and reconnect',
      () async {
        expect(
          await _coordinator(
            _Store([]),
            _Probe([], NativeProbeBoundaryFailure(boundary)),
            _Connector([]),
          ).begin(authority),
          _blocked(
            boundary == NativeTlsBoundaryFailure.cleanupFailed
                ? CertificateTrustCoordinatorFailure.cleanup
                : CertificateTrustCoordinatorFailure.nativeBoundary,
          ),
        );
        final pin = PinRecord(
          leafDerSha256: digest,
          createdAt: DateTime.utc(2026),
        );
        expect(
          await _coordinator(
            _Store([])..readResult = PinReadResult.record(pin),
            _Probe([], const NativeProbeBrowserManagedTls()),
            _Connector([])..outcome = NativePinnedBoundaryFailure(boundary),
          ).begin(authority),
          _blocked(
            boundary == NativeTlsBoundaryFailure.cleanupFailed
                ? CertificateTrustCoordinatorFailure.cleanup
                : CertificateTrustCoordinatorFailure.nativeBoundary,
          ),
        );
      },
    );
  }

  test(
    'cancelling a visible review terminalizes it and a later start is fresh',
    () async {
      final events = <String>[];
      final coordinator = _coordinator(
        _Store(events),
        _Probe(
          events,
          NativeProbeCertificate(
            PresentedCertificate(authority: authority, facts: facts),
          ),
        ),
        _Connector(events),
      );
      final first = coordinator.start(authority);
      final review = await first.state as FirstTrustReview;

      expect(
        await coordinator.cancel(review.token),
        _blocked(CertificateTrustCoordinatorFailure.cancelled),
      );
      final fresh = coordinator.start(authority);
      expect(fresh.token, isNot(same(first.token)));
      expect(await fresh.state, isA<FirstTrustReview>());
    },
  );

  test(
    'stored pin mismatch performs a credential-free replacement probe',
    () async {
      final events = <String>[];
      final old = PinRecord(
        leafDerSha256: digest,
        createdAt: DateTime.utc(2026),
      );
      final replacement = CertificateFacts(
        subjectSummary: 'replacement',
        issuerSummary: 'issuer',
        leafDerSha256: 'B' * 64,
        notValidBefore: DateTime.utc(2026),
        notValidAfter: DateTime.utc(2027),
      );
      final store = _Store(events)..active = old;
      final connector = _Connector(events)
        ..outcome = const NativePinnedFailure(
          CertificateTrustFailure.pinMismatch,
        );
      final result = await _coordinator(
        store,
        _Probe(
          events,
          NativeProbeCertificate(
            PresentedCertificate(authority: authority, facts: replacement),
          ),
        ),
        connector,
      ).begin(authority);
      expect(result, isA<ReplacementTrustReview>());
      expect(events, [
        'recover',
        'read',
        'read',
        'reconnect',
        'read',
        'probe',
        'read',
      ]);
    },
  );

  test(
    'replacement probe refuses reconnect when active changes while probing',
    () async {
      final events = <String>[];
      final old = PinRecord(
        leafDerSha256: digest,
        createdAt: DateTime.utc(2026),
      );
      final changed = PinRecord(
        leafDerSha256: 'C' * 64,
        createdAt: DateTime.utc(2026),
      );
      final wait = Completer<NativeProbeOutcome>();
      final store = _Store(events)..active = old;
      final probe = _Probe(
        events,
        const NativeProbeFailure(CertificateTrustFailure.cancelled),
      )..wait = wait;
      final connector = _Connector(events)
        ..outcome = NativePinnedVerified(_Transport());
      final pending = _coordinator(
        store,
        probe,
        connector,
      ).checkForReplacement(authority);
      await Future<void>.delayed(Duration.zero);
      store.active = changed;
      wait.complete(
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      );
      expect(
        await pending,
        _blocked(CertificateTrustCoordinatorFailure.candidateChanged),
      );
      expect(events, isNot(contains('reconnect')));
    },
  );

  test(
    'review exposes a typed platform-trust fact without a transport',
    () async {
      final review = await _coordinator(
        _Store([]),
        _Probe(
          [],
          NativeProbeCertificate(
            PresentedCertificate(
              authority: authority,
              facts: facts,
              platformTrust: PlatformTrust.didNotPass,
            ),
          ),
        ),
        _Connector([]),
      ).begin(authority) as FirstTrustReview;
      expect(review.certificate.platformTrust, PlatformTrust.didNotPass);
      expect(review.toString(), isNot(contains('didNotPass')));
    },
  );

  test('cleanup failures override cancellation and commit failures', () async {
    final probe = _Probe(
      [],
      const NativeProbeBoundaryFailure(NativeTlsBoundaryFailure.cleanupFailed),
    );
    expect(
      await _coordinator(_Store([]), probe, _Connector([])).begin(authority),
      _blocked(CertificateTrustCoordinatorFailure.cleanup),
    );

    final events = <String>[];
    final store = _Store(events)
      ..transactionCommit = const PinStoreResult.failure(
        PinStoreFailure.writeFailed,
      );
    final transport = _Transport()..throwClose = true;
    final coordinator = _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      ),
      _Connector(events)..outcome = NativePinnedVerified(transport),
    );
    final review = await coordinator.begin(authority) as FirstTrustReview;
    expect(
      await coordinator.approve(review.token),
      _blocked(CertificateTrustCoordinatorFailure.cleanup),
    );
    expect(transport.closeCount, 1);
  });

  test('abort result and throw are cleanup failures and occur once', () async {
    for (final throwing in [false, true]) {
      final events = <String>[];
      final store = _Store(events)
        ..transactionAbort = const PinStoreResult.failure(
          PinStoreFailure.writeFailed,
        )
        ..throwAbort = throwing;
      final coordinator = _coordinator(
        store,
        _Probe(
          events,
          NativeProbeCertificate(
            PresentedCertificate(authority: authority, facts: facts),
          ),
        ),
        _Connector(events)
          ..outcome = const NativePinnedFailure(
            CertificateTrustFailure.pinnedReconnectFailed,
          ),
      );
      final review = await coordinator.begin(authority) as FirstTrustReview;
      expect(
        await coordinator.approve(review.token),
        _blocked(CertificateTrustCoordinatorFailure.cleanup),
      );
      expect(store.lastTransaction!.abortCount, 1);
    }
  });

  test(
    'recovery and recovered-abort failures are typed and do not probe',
    () async {
      final failedRecovery = _Store([])
        ..recoveryResult = const PinRecoveryFailure(PinStoreFailure.readFailed);
      expect(
        await _coordinator(
          failedRecovery,
          _Probe([], const NativeProbeBrowserManagedTls()),
          _Connector([]),
        ).begin(authority),
        _blocked(CertificateTrustCoordinatorFailure.pinStore),
      );
      final throwingRecovery = _Store([])..throwRecovery = true;
      expect(
        await _coordinator(
          throwingRecovery,
          _Probe([], const NativeProbeBrowserManagedTls()),
          _Connector([]),
        ).begin(authority),
        _blocked(CertificateTrustCoordinatorFailure.pinStore),
      );
      for (final throwing in [false, true]) {
        final events = <String>[];
        final orphan = _Transaction(
          _Store(events),
          PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026)),
        );
        orphan.store
          ..recoveryResult = PinRecoverySuccess(orphan.replacement, orphan)
          ..transactionAbort = const PinStoreResult.failure(
            PinStoreFailure.deleteFailed,
          )
          ..throwAbort = throwing;
        expect(
          await _coordinator(
            orphan.store,
            _Probe(events, const NativeProbeBrowserManagedTls()),
            _Connector(events),
          ).begin(authority),
          _blocked(CertificateTrustCoordinatorFailure.cleanup),
        );
        expect(orphan.abortCount, 1);
        expect(events, ['recover']);
      }
    },
  );

  test(
    'duplicate approval shares exactly one stage reconnect and commit',
    () async {
      final events = <String>[];
      final coordinator = _coordinator(
        _Store(events),
        _Probe(
          events,
          NativeProbeCertificate(
            PresentedCertificate(authority: authority, facts: facts),
          ),
        ),
        _Connector(events)..outcome = NativePinnedVerified(_Transport()),
      );
      final review = await coordinator.begin(authority) as FirstTrustReview;
      final one = coordinator.approve(review.token);
      final two = coordinator.approve(review.token);
      expect(await one, isA<VerifiedTrustTransport>());
      expect(await two, isA<VerifiedTrustTransport>());
      expect(events.where((event) => event == 'stage'), hasLength(1));
      expect(events.where((event) => event == 'reconnect'), hasLength(1));
      expect(events.where((event) => event == 'commit'), hasLength(1));
    },
  );

  test('old terminal token cannot join a newer authority owner', () async {
    final events = <String>[];
    final coordinator = _coordinator(
      _Store(events),
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(authority: authority, facts: facts),
        ),
      ),
      _Connector(events),
    );
    final old = coordinator.start(authority);
    final review = await old.state as FirstTrustReview;
    await coordinator.cancel(review.token);
    final fresh = coordinator.start(authority);
    expect(
      await coordinator.retry(review.token),
      _blocked(CertificateTrustCoordinatorFailure.staleOperation),
    );
    expect(fresh.token, isNot(same(review.token)));
  });

  test(
    'partial-durable commit failure is never handed off and retry recovers',
    () async {
      final events = <String>[];
      final store = _Store(events)
        ..transactionCommit = const PinStoreResult.failure(
          PinStoreFailure.deleteFailed,
        );
      final firstTransport = _Transport();
      final connector = _Connector(events)
        ..outcome = NativePinnedVerified(firstTransport);
      final coordinator = _coordinator(
        store,
        _Probe(
          events,
          NativeProbeCertificate(
            PresentedCertificate(authority: authority, facts: facts),
          ),
        ),
        connector,
      );
      final review = await coordinator.begin(authority) as FirstTrustReview;
      store.onCommit = (transaction) {
        // Models PersistentPinStore's active-written/pending-cleanup failure.
        store.active = transaction.replacement;
        store.recoveryResult = PinRecoverySuccess(
          transaction.replacement,
          transaction,
        );
      };
      expect(
        await coordinator.approve(review.token),
        _blocked(CertificateTrustCoordinatorFailure.pinStore),
      );
      expect(firstTransport.closeCount, 1);
      final retryTransport = _Transport();
      connector.outcome = NativePinnedVerified(retryTransport);
      expect(
        await coordinator.retry(review.token),
        isA<VerifiedTrustTransport>(),
      );
      expect(store.lastTransaction!.abortCount, 1);
      expect(retryTransport.closeCount, 0);
    },
  );

  test(
    'a verified transport is never cached and its token is permanently inert',
    () async {
      final events = <String>[];
      final transport = _Transport();
      final coordinator = _coordinator(
        _Store(events),
        _Probe(
          events,
          NativeProbeCertificate(
            PresentedCertificate(
              authority: authority,
              facts: facts,
              platformTrust: PlatformTrust.passed,
            ),
          ),
        ),
        _Connector(events)..outcome = NativePinnedVerified(transport),
      );
      final review = await coordinator.begin(authority) as FirstTrustReview;
      expect(
        await coordinator.approve(review.token),
        isA<VerifiedTrustTransport>(),
      );
      expect(
        await coordinator.approve(review.token),
        _blocked(CertificateTrustCoordinatorFailure.invalidOperation),
      );
      expect(
        await coordinator.cancel(review.token),
        _blocked(CertificateTrustCoordinatorFailure.invalidOperation),
      );
      expect(
        await coordinator.retry(review.token),
        _blocked(CertificateTrustCoordinatorFailure.invalidOperation),
      );
      expect(transport.closeCount, 0);
    },
  );

  test('first-trust active pin appearing before stage is candidate-changed without side effects', () async {
    final events = <String>[];
    final competing = PinRecord(
      leafDerSha256: 'C' * 64,
      createdAt: DateTime.utc(2026),
    );
    final store = _Store(events);
    final coordinator = _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(
            authority: authority,
            facts: facts,
            platformTrust: PlatformTrust.passed,
          ),
        ),
      ),
      _Connector(events)..outcome = NativePinnedVerified(_Transport()),
    );
    final review = await coordinator.begin(authority) as FirstTrustReview;
    store.active = competing;
    expect(
      await coordinator.approve(review.token),
      _blocked(CertificateTrustCoordinatorFailure.candidateChanged),
    );
    expect(
      events.where((event) => event == 'stage' || event == 'reconnect'),
      isEmpty,
    );
  });

  test('replacement active changes before stage or during stage aborts exactly once', () async {
    for (final duringStage in [false, true]) {
      final events = <String>[];
      final old = PinRecord(
        leafDerSha256: digest,
        createdAt: DateTime.utc(2026),
      );
      final changed = PinRecord(
        leafDerSha256: 'C' * 64,
        createdAt: DateTime.utc(2026, 2),
      );
      final replacement = CertificateFacts(
        subjectSummary: 'new',
        issuerSummary: 'CA',
        leafDerSha256: 'B' * 64,
        notValidBefore: DateTime.utc(2026),
        notValidAfter: DateTime.utc(2027),
      );
      final store = _Store(events)..active = old;
      if (duringStage) store.onStage = () => store.active = changed;
      final coordinator = _coordinator(
        store,
        _Probe(
          events,
          NativeProbeCertificate(
            PresentedCertificate(
              authority: authority,
              facts: replacement,
              platformTrust: PlatformTrust.passed,
            ),
          ),
        ),
        _Connector(events)..outcome = NativePinnedVerified(_Transport()),
      );
      final review = await coordinator.checkForReplacement(
        authority,
      ) as ReplacementTrustReview;
      if (!duringStage) {
        // Exercise both a vanished old candidate and a replacement which
        // arrives before the user can stage their reviewed choice.
        store.active = null;
        store.active = changed;
      }
      expect(
        await coordinator.approve(review.token),
        _blocked(CertificateTrustCoordinatorFailure.candidateChanged),
      );
      expect(events.where((event) => event == 'reconnect'), isEmpty);
      expect(store.lastTransaction?.abortCount ?? 0, duringStage ? 1 : 0);
    }
  });

  test('replacement active changes during reconnect closes then aborts exactly once', () async {
    final events = <String>[];
    final old = PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026));
    final changed = PinRecord(
      leafDerSha256: 'C' * 64,
      createdAt: DateTime.utc(2026, 2),
    );
    final replacement = CertificateFacts(
      subjectSummary: 'new',
      issuerSummary: 'CA',
      leafDerSha256: 'B' * 64,
      notValidBefore: DateTime.utc(2026),
      notValidAfter: DateTime.utc(2027),
    );
    final store = _Store(events)..active = old;
    final transport = _Transport();
    final connector = _Connector(events)
      ..wait = Completer<NativePinnedOutcome>();
    final coordinator = _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(
            authority: authority,
            facts: replacement,
            platformTrust: PlatformTrust.passed,
          ),
        ),
      ),
      connector,
    );
    final review = await coordinator.checkForReplacement(
      authority,
    ) as ReplacementTrustReview;
    final approval = coordinator.approve(review.token);
    await Future<void>.delayed(Duration.zero);
    store.active = changed;
    connector.wait!.complete(NativePinnedVerified(transport));
    expect(
      await approval,
      _blocked(CertificateTrustCoordinatorFailure.candidateChanged),
    );
    expect(transport.closeCount, 1);
    expect(store.lastTransaction!.abortCount, 1);
  });

  test('commit replacement-changed preserves external active and closes verified transport once', () async {
    final events = <String>[];
    final external = PinRecord(
      leafDerSha256: 'C' * 64,
      createdAt: DateTime.utc(2026, 2),
    );
    final store = _Store(events);
    store.transactionCommit = const PinStoreResult.failure(
      PinStoreFailure.replacementChanged,
    );
    store.onCommit = (_) => store.active = external;
    final transport = _Transport();
    final coordinator = _coordinator(
      store,
      _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(
            authority: authority,
            facts: facts,
            platformTrust: PlatformTrust.passed,
          ),
        ),
      ),
      _Connector(events)..outcome = NativePinnedVerified(transport),
    );
    final review = await coordinator.begin(authority) as FirstTrustReview;
    expect(
      await coordinator.approve(review.token),
      _blocked(CertificateTrustCoordinatorFailure.pinStore),
    );
    expect(store.active, same(external));
    expect(transport.closeCount, 1);
    expect(store.lastTransaction!.abortCount, 0);
  });

  test(
    'review active reads fail closed before stage and after stage aborts once',
    () async {
      for (final postStage in [false, true]) {
        final events = <String>[];
        final store = _Store(events);
        final coordinator = _coordinator(
          store,
          _Probe(
            events,
            NativeProbeCertificate(
              PresentedCertificate(
                authority: authority,
                facts: facts,
                platformTrust: PlatformTrust.passed,
              ),
            ),
          ),
          _Connector(events),
        );
        final review = await coordinator.begin(authority) as FirstTrustReview;
        if (postStage) {
          store.onStage = () => store.throwRead = true;
        } else {
          store.throwRead = true;
        }
        expect(
          await coordinator.approve(review.token),
          _blocked(CertificateTrustCoordinatorFailure.pinStore),
        );
        expect(store.lastTransaction?.abortCount ?? 0, postStage ? 1 : 0);
        expect(events.where((event) => event == 'reconnect'), isEmpty);
      }
    },
  );

  test(
    'unmeasured native review is rejected before it can become review UI',
    () async {
      final state = await _coordinator(
        _Store([]),
        _Probe(
          [],
          NativeProbeCertificate(
            PresentedCertificate(authority: authority, facts: facts),
          ),
        )..preservePlatformTrust = true,
        _Connector([]),
      ).begin(authority);
      expect(
        state,
        _blocked(CertificateTrustCoordinatorFailure.malformedCertificate),
      );
    },
  );

  test(
    'PersistentPinStore recovery aborts pending-only before fresh probe',
    () async {
      final raw = InMemoryRawPinStorage();
      final pending = PinRecord(
        leafDerSha256: 'C' * 64,
        createdAt: DateTime.utc(2026),
      );
      raw.values[PersistentPinStore.pendingKey(authority)] = jsonEncode({
        'authority': authority.pinKey,
        'record': pending.toJson(),
      });
      final events = <String>[];
      final state = await _persistentCoordinator(
        PersistentPinStore(raw),
        events,
        authority: authority,
        facts: facts,
      ).begin(authority);
      expect(state, isA<FirstTrustReview>());
      expect(raw.values[PersistentPinStore.activeKey(authority)], isNull);
      expect(raw.values[PersistentPinStore.pendingKey(authority)], isNull);
      expect(events, contains('probe'));
    },
  );

  test('PersistentPinStore cleans matching durable pending then reconnects exact active without probe', () async {
    final raw = InMemoryRawPinStorage();
    final pin = PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026));
    final envelope = jsonEncode({
      'authority': authority.pinKey,
      'record': pin.toJson(),
    });
    raw.values[PersistentPinStore.activeKey(authority)] = envelope;
    raw.values[PersistentPinStore.pendingKey(authority)] = envelope;
    final events = <String>[];
    final transport = _Transport();
    final connector = _Connector(events)
      ..outcome = NativePinnedVerified(transport);
    final coordinator = CertificateTrustCoordinator(
      pinStore: PersistentPinStore(raw),
      probe: _Probe(
        events,
        NativeProbeCertificate(
          PresentedCertificate(
            authority: authority,
            facts: facts,
            platformTrust: PlatformTrust.passed,
          ),
        ),
      ),
      connector: connector,
      now: () => DateTime.utc(2026),
      probeTimeout: const Duration(seconds: 1),
      reconnectTimeout: const Duration(seconds: 1),
    );
    expect(await coordinator.begin(authority), isA<VerifiedTrustTransport>());
    expect(raw.values[PersistentPinStore.activeKey(authority)], envelope);
    expect(raw.values[PersistentPinStore.pendingKey(authority)], isNull);
    expect(events, isNot(contains('probe')));
    expect(connector.pin, pin);
    expect(transport.closeCount, 0);
  });

  test('pre-active-write commit failure releases persistent transaction ownership for retry', () async {
    final raw = _FailActiveWriteRawPinStorage();
    final store = PersistentPinStore(raw);
    final old = PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026));
    expect(
      await (await store.stageReplacement(authority, old) as PinStageSuccess)
          .transaction
          .commit(),
      const PinStoreResult.success(),
    );
    final events = <String>[];
    final coordinator = _persistentCoordinator(
      store,
      events,
      authority: authority,
      facts: CertificateFacts(
        subjectSummary: facts.subjectSummary,
        issuerSummary: facts.issuerSummary,
        leafDerSha256: 'E' * 64,
        notValidBefore: facts.notValidBefore,
        notValidAfter: facts.notValidAfter,
      ),
    );
    final review = await coordinator.checkForReplacement(
      authority,
    ) as ReplacementTrustReview;
    raw.failNextActiveWrite();

    expect(
      await coordinator.approve(review.token),
      _blocked(CertificateTrustCoordinatorFailure.pinStore),
    );
    expect(await store.read(authority), PinReadResult.record(old));
    expect(raw.values[PersistentPinStore.pendingKey(authority)], isNull);

    final retried = await coordinator.retry(review.token);
    expect(retried, isA<VerifiedTrustTransport>());
    expect(await store.read(authority), PinReadResult.record(old));
    expect(raw.values[PersistentPinStore.pendingKey(authority)], isNull);
    expect(events.where((event) => event == 'probe'), hasLength(1));
  });
}

CertificateTrustCoordinator _coordinator(
  PinStore store,
  _Probe probe,
  _Connector connector,
) => CertificateTrustCoordinator(
  pinStore: store,
  probe: probe,
  connector: connector,
  now: () => DateTime.utc(2026),
  probeTimeout: const Duration(seconds: 1),
  reconnectTimeout: const Duration(seconds: 1),
);

CertificateTrustCoordinator _persistentCoordinator(
  PersistentPinStore store,
  List<String> events, {
  required NormalizedAuthority authority,
  required CertificateFacts facts,
  _Transport? transport,
}) => CertificateTrustCoordinator(
  pinStore: store,
  probe: _Probe(
    events,
    NativeProbeCertificate(
      PresentedCertificate(
        authority: authority,
        facts: facts,
        platformTrust: PlatformTrust.passed,
      ),
    ),
  ),
  connector: _Connector(events)
    ..outcome = NativePinnedVerified(transport ?? _Transport()),
  now: () => DateTime.utc(2026),
  probeTimeout: const Duration(seconds: 1),
  reconnectTimeout: const Duration(seconds: 1),
);

Matcher _blocked(CertificateTrustCoordinatorFailure failure) =>
    isA<BlockedTrust>().having((state) => state.failure, 'failure', failure);

CertificateTrustCoordinatorFailure _expectedFailure(
  CertificateTrustFailure failure,
) => switch (failure) {
  CertificateTrustFailure.cancelled =>
    CertificateTrustCoordinatorFailure.cancelled,
  CertificateTrustFailure.malformedCertificate =>
    CertificateTrustCoordinatorFailure.malformedCertificate,
  CertificateTrustFailure.hostnameMismatch =>
    CertificateTrustCoordinatorFailure.hostnameMismatch,
  CertificateTrustFailure.expiredCertificate =>
    CertificateTrustCoordinatorFailure.expiredCertificate,
  CertificateTrustFailure.notYetValidCertificate =>
    CertificateTrustCoordinatorFailure.notYetValidCertificate,
  CertificateTrustFailure.pinMismatch =>
    CertificateTrustCoordinatorFailure.pinMismatch,
  CertificateTrustFailure.probeTimedOut =>
    CertificateTrustCoordinatorFailure.probeTimedOut,
  CertificateTrustFailure.pinStoreFailure =>
    CertificateTrustCoordinatorFailure.pinStore,
  // A reconnect cannot be delegated to browser TLS: it is a typed boundary
  // outcome, distinct from an arbitrary connector exception.
  CertificateTrustFailure.browserManagedTls =>
    CertificateTrustCoordinatorFailure.nativeBoundary,
  _ => CertificateTrustCoordinatorFailure.pinnedReconnectFailed,
};

final class _Store implements PinStore {
  _Store(this.events);
  final List<String> events;
  PinReadResult readResult = const PinAbsent();
  PinRecoveryResult recoveryResult = const PinRecoveryNone();
  bool throwRecovery = false;
  var commitCount = 0;
  PinRecord? active;
  bool throwRead = false;
  Completer<PinReadResult>? readWait;
  Completer<void>? readStarted;
  bool throwStage = false;
  bool throwAbort = false;
  void Function()? onStage;
  Completer<PinStageResult>? stageWait;
  PinStoreResult transactionCommit = const PinStoreSuccess();
  PinStoreResult transactionAbort = const PinStoreSuccess();
  Completer<PinStoreResult>? commitWait;
  bool throwCommit = false;
  void Function(_Transaction transaction)? onCommit;
  _Transaction? lastTransaction;
  @override
  Future<PinReadResult> read(NormalizedAuthority authority) async {
    events.add('read');
    readStarted?.complete();
    if (throwRead) throw StateError('secret native detail');
    if (readWait != null) return readWait!.future;
    if (active != null) return PinReadResult.record(active!);
    if (readResult case PinRecordRead(:final record)) active ??= record;
    return readResult;
  }

  @override
  Future<PinStageResult> stageReplacement(
    NormalizedAuthority authority,
    PinRecord replacement,
  ) async {
    events.add('stage');
    if (throwStage) throw StateError('secret native detail');
    onStage?.call();
    if (stageWait != null) return stageWait!.future;
    return PinStageSuccess(lastTransaction = _Transaction(this, replacement));
  }

  @override
  Future<PinRecoveryResult> recoverReplacement(
    NormalizedAuthority authority,
  ) async {
    events.add('recover');
    if (throwRecovery) throw StateError('secret recovery detail');
    return recoveryResult;
  }
}

final class _Transaction implements PinStoreTransaction {
  _Transaction(this.store, this.replacement);
  final _Store store;
  final PinRecord replacement;
  var abortCount = 0;
  @override
  Future<PinStoreResult> abort() async {
    abortCount++;
    if (store.throwAbort) throw StateError('secret abort detail');
    return store.transactionAbort;
  }

  @override
  Future<PinStoreResult> commit() async {
    store.events.add('commit');
    store.commitCount++;
    if (store.throwCommit) throw StateError('secret commit detail');
    final Future<PinStoreResult> resultFuture =
        store.commitWait?.future ?? Future.value(store.transactionCommit);
    final result = await resultFuture;
    store.onCommit?.call(this);
    if (result is PinStoreSuccess) store.active = replacement;
    return result;
  }
}

final class _Probe implements NativeCertificateProbe {
  _Probe(this.events, this.outcome);
  final List<String> events;
  final NativeProbeOutcome outcome;
  Completer<NativeProbeOutcome>? wait;
  Map<NormalizedAuthority, NativeProbeOutcome>? byAuthority;
  bool preservePlatformTrust = false;
  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    events.add('probe');
    final value =
        await (wait?.future ??
            Future.value(byAuthority?[authority] ?? outcome));
    if (preservePlatformTrust ||
        value is! NativeProbeCertificate ||
        value.certificate.platformTrust != PlatformTrust.notAvailable) {
      return value;
    }
    // Coordinator fixtures model a native adapter, which always reports a
    // measured result. Individual tests opt out to exercise fail-closed input.
    return NativeProbeCertificate(
      PresentedCertificate(
        authority: value.certificate.authority,
        facts: value.certificate.facts,
        platformTrust: PlatformTrust.didNotPass,
      ),
    );
  }
}

final class _Connector implements PinnedRpcConnector {
  _Connector(this.events);
  final List<String> events;
  NativePinnedOutcome? outcome;
  Completer<NativePinnedOutcome>? wait;
  Map<NormalizedAuthority, Completer<NativePinnedOutcome>>? waitsByAuthority;
  bool throwReconnect = false;
  PinRecord? pin;
  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    events.add('reconnect');
    this.pin = pin;
    if (throwReconnect) {
      return Future.error(StateError('secret connector detail'));
    }
    return waitsByAuthority?[authority]?.future ??
        wait?.future ??
        Future.value(outcome);
  }
}

final class _Transport implements RpcTransport {
  var closeCount = 0;
  var sendCount = 0;
  bool throwClose = false;
  @override
  Stream<String> get inboundFrames => const Stream<String>.empty();
  @override
  Future<void> send(String frame) async {
    sendCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
    if (throwClose) throw StateError('secret close detail');
  }
}

final class _FailActiveWriteRawPinStorage implements RawPinStorage {
  final _delegate = InMemoryRawPinStorage();
  bool _failNextActiveWrite = false;

  Map<String, String> get values => _delegate.values;
  void failNextActiveWrite() => _failNextActiveWrite = true;

  @override
  Future<RawPinReadResult> read(String key) => _delegate.read(key);
  @override
  Future<RawPinStorageResult> write(String key, String value) =>
      _delegate.write(key, value);
  @override
  Future<RawPinStorageResult> delete(String key) => _delegate.delete(key);
  @override
  Future<RawPinStorageResult> deleteIfValue(String key, String expectedValue) =>
      _delegate.deleteIfValue(key, expectedValue);
  @override
  Future<RawPinStorageResult> writeIfValue(
    String key,
    String? expectedValue,
    String value,
  ) => _delegate.writeIfValue(key, expectedValue, value);
  @override
  Future<RawPinStorageResult> writeIfValues(
    String key,
    String? expectedValue,
    String guardKey,
    String expectedGuardValue,
    String value,
  ) {
    if (_failNextActiveWrite) {
      _failNextActiveWrite = false;
      return Future.value(
        const RawPinStorageOperationFailure(RawPinStorageFailure.writeFailed),
      );
    }
    return _delegate.writeIfValues(
      key,
      expectedValue,
      guardKey,
      expectedGuardValue,
      value,
    );
  }
}
