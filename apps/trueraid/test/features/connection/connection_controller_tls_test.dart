import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/connection/connection_state.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/server_profiles/server_profiles_controller.dart';
import 'package:trueraid/features/tls_trust/certificate_facts.dart';
import 'package:trueraid/features/tls_trust/certificate_trust_coordinator.dart';
import 'package:trueraid/features/tls_trust/models.dart';
import 'package:trueraid/features/tls_trust/native_tls_ports.dart';
import 'package:trueraid/features/tls_trust/pin_store.dart';
import 'package:trueraid/features/tls_trust/tls_trust_providers.dart';
import 'package:truenas_api/truenas_api.dart';

const _sentinel = 'test-api-key';
final _digest = List<String>.filled(64, 'A').join();

void main() {
  test(
    'first trust withholds credentials until approval returns transport',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final transport = _Transport();
      final coordinator = _coordinator(
        authority: authority,
        platformTrust: PlatformTrust.didNotPass,
        transport: transport,
      );
      late _Repository verifiedRepository;
      final normalRepository = _Repository();
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          certificateTrustCoordinatorProvider.overrideWithValue(coordinator),
          sessionRepositoryProvider.overrideWithValue(normalRepository),
          sessionRepositoryFactoryProvider.overrideWithValue(
            ({required connector, required credentialVault}) =>
                verifiedRepository = _Repository(connector: connector),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
            rememberApiKey: true,
          );

      final review = container.read(connectionControllerProvider);
      expect(
        review,
        isA<ConnectionFirstTrustReview>().having(
          (value) => value.certificate.leafDerSha256,
          'display digest',
          _digest,
        ),
      );
      expect(normalRepository.apiKeys, isEmpty);

      await container
          .read(connectionControllerProvider.notifier)
          .approveTrust(
            apiKey: _sentinel,
            username: 'test-account',
            rememberApiKey: true,
          );

      expect(verifiedRepository.apiKeys, [_sentinel]);
      expect(verifiedRepository.rememberApiKeyIntents, [true]);
      expect(verifiedRepository.connectedEndpoints, [
        authority.rpcConnectionUri,
      ]);
      await expectLater(
        verifiedRepository.connector!.connect(authority.rpcConnectionUri),
        throwsStateError,
      );
    },
  );

  test(
    'approval failure retains the review token as a typed blocked state',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final coordinator = CertificateTrustCoordinator(
        pinStore: InMemoryPinStore(),
        probe: _Probe(
          NativeProbeCertificate(
            PresentedCertificate(
              namesAuthority: true,
              authority: authority,
              platformTrust: PlatformTrust.didNotPass,
              facts: CertificateFacts(
                subjectSummary: 'nas.example',
                issuerSummary: 'issuer',
                leafDerSha256: _digest,
                notValidBefore: DateTime.utc(2026),
                notValidAfter: DateTime.utc(2027),
              ),
            ),
          ),
        ),
        connector: _Connector(
          const NativePinnedFailure(CertificateTrustFailure.pinMismatch),
        ),
        now: () => DateTime.utc(2026, 2),
        probeTimeout: const Duration(seconds: 1),
        reconnectTimeout: const Duration(seconds: 1),
      );
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          certificateTrustCoordinatorProvider.overrideWithValue(coordinator),
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );
      final review = container.read(
        connectionControllerProvider,
      ) as ConnectionFirstTrustReview;
      await container
          .read(connectionControllerProvider.notifier)
          .approveTrust(apiKey: _sentinel, username: 'test-account');

      final blocked = container.read(connectionControllerProvider);
      expect(blocked, isA<ConnectionTrustBlocked>());
      expect((blocked as ConnectionTrustBlocked).token, same(review.token));
      expect(repository.apiKeys, isEmpty);
    },
  );

  test(
    'review state exposes only display-safe current and previous digests',
    () async {
      final certificate = TrustReviewCertificate(
        namesAuthority: true,
        subjectSummary: 'nas.example',
        issuerSummary: 'issuer',
        leafDerSha256: _digest,
        notValidBefore: DateTime.utc(2026),
        notValidAfter: DateTime.utc(2027),
        platformTrust: PlatformTrust.didNotPass,
      );
      expect(certificate.leafDerSha256, _digest);
    },
  );

  test(
    'platform-validated route passes remember intent to the normal repository',
    () async {
      final repository = _Repository(
        error: const AuthenticationStateException(
          AuthenticationState.authenticationFailed,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(
            TlsTrustRoute.platformValidated,
          ),
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
            rememberApiKey: true,
          );

      expect(repository.apiKeys, [_sentinel]);
      expect(repository.rememberApiKeyIntents, [true]);
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>().having(
          (value) => value.message,
          'message',
          'The server rejected the API key.',
        ),
      );
    },
  );

  test(
    'web is browser-managed before any coordinator or repository work',
    () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.browserManaged),
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );

      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionBrowserManagedTls>(),
      );
      expect(repository.apiKeys, isEmpty);
    },
  );

  test(
    'replacing a review with malformed input does not leave connect busy',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final coordinator = _coordinator(
        authority: authority,
        platformTrust: PlatformTrust.didNotPass,
        transport: _Transport(),
      );
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          certificateTrustCoordinatorProvider.overrideWithValue(coordinator),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);

      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFirstTrustReview>(),
      );
      await controller.connect(
        serverInput: 'not a server',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>(),
      );
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );

      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFirstTrustReview>(),
      );
    },
  );

  test(
    'repository success without consuming verified connector fails closed',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final transport = _CountingTransport();
      final coordinator = _coordinator(
        authority: authority,
        platformTrust: PlatformTrust.didNotPass,
        transport: transport,
      );
      late _Repository repository;
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          certificateTrustCoordinatorProvider.overrideWithValue(coordinator),
          sessionRepositoryFactoryProvider.overrideWithValue(
            ({required connector, required credentialVault}) =>
                repository = _Repository(connector: connector, consume: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      await controller.approveTrust(
        apiKey: _sentinel,
        username: 'test-account',
      );

      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>(),
      );
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
      expect(transport.closeCalls, 1);
      expect(repository.closeCalls, 1);
    },
  );

  test(
    'browser route is lazy even when TLS and repository seams throw',
    () async {
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.browserManaged),
          pinStoreProvider.overrideWith((ref) => throw StateError('pin store')),
          nativeCertificateProbeProvider.overrideWith(
            (ref) => throw StateError('probe'),
          ),
          pinnedRpcConnectorProvider.overrideWith(
            (ref) => throw StateError('connector'),
          ),
          sessionRepositoryProvider.overrideWith(
            (ref) => throw StateError('normal repository'),
          ),
          sessionRepositoryFactoryProvider.overrideWith(
            (ref) =>
                ({required connector, required credentialVault}) =>
                    throw StateError('repository factory'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );

      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionBrowserManagedTls>(),
      );
    },
  );

  test('platform-validated route never instantiates TLS trust seams', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWithValue(
          TlsTrustRoute.platformValidated,
        ),
        pinStoreProvider.overrideWith((ref) => throw StateError('pin store')),
        nativeCertificateProbeProvider.overrideWith(
          (ref) => throw StateError('probe'),
        ),
        pinnedRpcConnectorProvider.overrideWith(
          (ref) => throw StateError('connector'),
        ),
        sessionRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(connectionControllerProvider.notifier)
        .connect(
          serverInput: 'https://nas.example',
          apiKey: _sentinel,
          username: 'test-account',
        );

    expect(repository.apiKeys, [_sentinel]);
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionSucceeded>(),
    );
  });

  test(
    'provider-composed first trust reads, probes, and withholds credentials',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final events = <String>[];
      final store = _RecordingStore(events);
      final probe = _Probe(_certificate(authority), events: events);
      final connector = _Connector(
        NativePinnedVerified(_Transport()),
        events: events,
      );
      final repository = _Repository(events: events);
      final vault = _Vault();
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          pinStoreProvider.overrideWithValue(store),
          nativeCertificateProbeProvider.overrideWithValue(probe),
          pinnedRpcConnectorProvider.overrideWithValue(connector),
          sessionRepositoryProvider.overrideWithValue(repository),
          credentialVaultProvider.overrideWithValue(vault),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFirstTrustReview>(),
      );
      expect(events.take(3), ['recover', 'read', 'probe']);
      expect(events, isNot(contains(_sentinel)));
      expect(repository.apiKeys, isEmpty);
      expect(vault.calls, 0);
    },
  );

  test(
    'matching active pin reconnects before credentials reach repository',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final store = InMemoryPinStore();
      await _seed(store, authority, _digest);
      final transport = _Transport();
      final probe = _Probe(_certificate(authority));
      final connector = _Connector(NativePinnedVerified(transport));
      _Repository? repository;
      final container = _nativeContainer(
        store: store,
        probe: probe,
        connector: connector,
        factory: ({required connector, required credentialVault}) {
          final created = _Repository(connector: connector);
          repository = created;
          return created;
        },
      );
      addTearDown(container.dispose);
      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
            rememberApiKey: true,
          );
      final connectedRepository = repository;
      expect(
        connectedRepository,
        isNotNull,
        reason: 'matching pin must hand the verified transport to auth',
      );
      expect(probe.calls, 0);
      expect(connectedRepository!.apiKeys, [_sentinel]);
      expect(connectedRepository.rememberApiKeyIntents, [true]);
      expect(connectedRepository.connectedEndpoints, [
        authority.rpcConnectionUri,
      ]);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        hasLength(1),
      );
    },
  );

  test(
    'replacement review exposes old and new pins without authentication',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final old = List<String>.filled(64, 'B').join();
      final store = InMemoryPinStore();
      await _seed(store, authority, old);
      final repository = _Repository();
      final container = _nativeContainer(
        store: store,
        probe: _Probe(_certificate(authority)),
        connector: _Connector(
          const NativePinnedFailure(CertificateTrustFailure.pinMismatch),
        ),
        normal: repository,
      );
      addTearDown(container.dispose);
      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );
      final review = container.read(
        connectionControllerProvider,
      ) as ConnectionReplacementTrustReview;
      expect(review.previousPin.leafDerSha256, old);
      expect(review.certificate.leafDerSha256, _digest);
      expect(repository.apiKeys, isEmpty);
    },
  );

  test(
    'replacement approval commits the new pin before verified authentication',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final old = List<String>.filled(64, 'B').join();
      final events = <String>[];
      final store = _EventStore(events);
      await _seed(store, authority, old);
      events.clear();
      final transport = _CountingTransport();
      _Repository? repository;
      final container = _nativeContainer(
        store: store,
        probe: _Probe(_certificate(authority), events: events),
        connector: _SequenceConnector([
          const NativePinnedFailure(CertificateTrustFailure.pinMismatch),
          NativePinnedVerified(transport),
        ], events: events),
        factory: ({required connector, required credentialVault}) =>
            repository = _Repository(connector: connector, events: events),
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);

      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      final review = container.read(
        connectionControllerProvider,
      ) as ConnectionReplacementTrustReview;
      expect(review.previousPin.leafDerSha256, old);
      expect(review.certificate.leafDerSha256, _digest);
      expect(repository, isNull);

      await controller.approveTrust(
        apiKey: _sentinel,
        username: 'test-account',
        rememberApiKey: true,
      );

      expect(repository!.apiKeys, [_sentinel]);
      expect(repository!.rememberApiKeyIntents, [true]);
      expect(
        events.indexOf('commit'),
        lessThan(events.indexOf('repositoryAuth')),
      );
      expect(events.indexOf('reconnect'), lessThan(events.indexOf('commit')));
      expect(
        (await store.read(authority) as PinRecordRead).record.leafDerSha256,
        _digest,
      );
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        hasLength(1),
      );
      expect(
        '$review ${container.read(connectionControllerProvider)}',
        isNot(contains(_sentinel)),
      );
    },
  );

  test('synchronous normal repository failures are safe and later connections recover', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    for (final route in [
      TlsTrustRoute.platformValidated,
      TlsTrustRoute.native,
    ]) {
      var fail = true;
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(route),
          if (route == TlsTrustRoute.native) ...[
            certificateTrustCoordinatorProvider.overrideWithValue(
              _coordinator(
                authority: authority,
                platformTrust: PlatformTrust.passed,
                transport: _Transport(),
              ),
            ),
          ],
          sessionRepositoryProvider.overrideWith((ref) {
            if (fail) throw StateError(_sentinel);
            return repository;
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);

      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>(),
      );
      expect(
        '${container.read(connectionControllerProvider)}',
        isNot(contains(_sentinel)),
      );
      fail = false;
      container.invalidate(sessionRepositoryProvider);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionSucceeded>(),
      );
      expect(repository.apiKeys, [_sentinel]);
    }
  });

  test(
    'credential vault remains unused on every controller trust route',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final routes = <Future<void> Function(_Vault)>[
        (vault) async {
          final container = _nativeContainer(
            store: InMemoryPinStore(),
            probe: _Probe(_certificate(authority)),
            connector: _Connector(NativePinnedVerified(_Transport())),
            factory: ({required connector, required credentialVault}) =>
                _Repository(connector: connector),
            credentialVault: vault,
          );
          await container
              .read(connectionControllerProvider.notifier)
              .connect(
                serverInput: 'https://nas.example',
                apiKey: _sentinel,
                username: 'test-account',
              );
          await container
              .read(connectionControllerProvider.notifier)
              .approveTrust(apiKey: _sentinel, username: 'test-account');
          container.dispose();
        },
        (vault) async {
          final store = InMemoryPinStore();
          await _seed(store, authority, _digest);
          final container = _nativeContainer(
            store: store,
            probe: _Probe(_certificate(authority)),
            connector: _Connector(NativePinnedVerified(_Transport())),
            factory: ({required connector, required credentialVault}) =>
                _Repository(connector: connector),
            credentialVault: vault,
          );
          await container
              .read(connectionControllerProvider.notifier)
              .connect(
                serverInput: 'https://nas.example',
                apiKey: _sentinel,
                username: 'test-account',
              );
          container.dispose();
        },
        (vault) async {
          final store = InMemoryPinStore();
          await _seed(store, authority, List<String>.filled(64, 'B').join());
          final container = _nativeContainer(
            store: store,
            probe: _Probe(_certificate(authority)),
            connector: _SequenceConnector([
              const NativePinnedFailure(CertificateTrustFailure.pinMismatch),
              NativePinnedVerified(_Transport()),
            ]),
            factory: ({required connector, required credentialVault}) =>
                _Repository(connector: connector),
            credentialVault: vault,
          );
          final controller = container.read(
            connectionControllerProvider.notifier,
          );
          await controller.connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );
          await controller.approveTrust(
            apiKey: _sentinel,
            username: 'test-account',
          );
          container.dispose();
        },
        (vault) async {
          final container = _nativeContainer(
            store: InMemoryPinStore(),
            probe: _Probe(_certificate(authority, PlatformTrust.passed)),
            connector: _Connector(NativePinnedVerified(_Transport())),
            normal: _Repository(),
            credentialVault: vault,
          );
          await container
              .read(connectionControllerProvider.notifier)
              .connect(
                serverInput: 'https://nas.example',
                apiKey: _sentinel,
                username: 'test-account',
              );
          container.dispose();
        },
        (vault) async {
          final container = ProviderContainer(
            overrides: [
              tlsTrustRouteProvider.overrideWithValue(
                TlsTrustRoute.platformValidated,
              ),
              credentialVaultProvider.overrideWithValue(vault),
              sessionRepositoryProvider.overrideWithValue(_Repository()),
            ],
          );
          await container
              .read(connectionControllerProvider.notifier)
              .connect(
                serverInput: 'https://nas.example',
                apiKey: _sentinel,
                username: 'test-account',
              );
          container.dispose();
        },
      ];
      for (final run in routes) {
        final vault = _Vault();
        await run(vault);
        expect(vault.calls, 0);
      }
    },
  );

  test('disposing during delayed verified authentication closes transport without publishing', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final transport = _CountingTransport();
    final repositoryReady = Completer<_DelayedRepository>();
    final container = _nativeContainer(
      store: InMemoryPinStore(),
      probe: _Probe(_certificate(authority)),
      connector: _Connector(NativePinnedVerified(transport)),
      factory: ({required connector, required credentialVault}) {
        final repository = _DelayedRepository(connector);
        repositoryReady.complete(repository);
        return repository;
      },
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    final approving = controller.approveTrust(
      apiKey: _sentinel,
      username: 'test-account',
    );
    final repository = await repositoryReady.future;
    await repository.started.future;
    container.invalidate(connectionControllerProvider);
    repository.complete();
    await approving;
    expect(container.read(serverProfilesControllerProvider).profiles, isEmpty);
    expect(transport.closeCalls, 1);
  });

  test(
    'stale initial connect closes its unhanded verified transport once',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final store = InMemoryPinStore();
      await _seed(store, authority, _digest);
      final transport = _CountingTransport();
      final connector = _DelayedConnector();
      final repository = _Repository();
      final container = _nativeContainer(
        store: store,
        probe: _Probe(_certificate(authority)),
        connector: connector,
        normal: repository,
      );
      addTearDown(container.dispose);
      final connecting = container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );

      await connector.started.future;
      container.invalidate(connectionControllerProvider);
      connector.complete(NativePinnedVerified(transport));
      await connecting;

      expect(repository.apiKeys, isEmpty);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionIdle>(),
      );
      expect(transport.closeCalls, 1);
    },
  );

  test('stale approval closes its unhanded verified transport once', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final transport = _CountingTransport();
    final connector = _DelayedConnector();
    final repository = _Repository();
    final container = _nativeContainer(
      store: InMemoryPinStore(),
      probe: _Probe(_certificate(authority)),
      connector: connector,
      normal: repository,
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    final approving = controller.approveTrust(
      apiKey: _sentinel,
      username: 'test-account',
    );

    await connector.started.future;
    container.invalidate(connectionControllerProvider);
    connector.complete(NativePinnedVerified(transport));
    await approving;

    expect(repository.apiKeys, isEmpty);
    expect(container.read(serverProfilesControllerProvider).profiles, isEmpty);
    expect(container.read(connectionControllerProvider), isA<ConnectionIdle>());
    expect(transport.closeCalls, 1);
  });

  test('stale retry closes its unhanded verified transport once', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final store = InMemoryPinStore();
    final transport = _CountingTransport();
    final connector = _DelayedConnector();
    final repository = _Repository();
    final container = _nativeContainer(
      store: store,
      probe: _Probe(_certificate(authority)),
      connector: connector,
      normal: repository,
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await controller.cancelTrust();
    await _seed(store, authority, _digest);
    final retrying = controller.retryTrust(
      apiKey: _sentinel,
      username: 'test-account',
    );

    await connector.started.future;
    container.invalidate(connectionControllerProvider);
    connector.complete(NativePinnedVerified(transport));
    await retrying;

    expect(repository.apiKeys, isEmpty);
    expect(container.read(serverProfilesControllerProvider).profiles, isEmpty);
    expect(container.read(connectionControllerProvider), isA<ConnectionIdle>());
    expect(transport.closeCalls, 1);
  });

  test(
    'disposing during visible-review cancellation does not start another probe',
    () async {
      final events = <String>[];
      final repository = _Repository(events: events);
      final container = _nativeContainer(
        store: _RecordingStore(events),
        probe: _AuthorityProbe(events),
        connector: _Connector(
          NativePinnedVerified(_Transport()),
          events: events,
        ),
        normal: repository,
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://old.example',
        apiKey: _sentinel,
        username: 'test-account',
      );

      final switching = controller.connect(
        serverInput: 'https://new.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      container.invalidate(connectionControllerProvider);
      await switching;

      expect(events.where((event) => event == 'probe'), hasLength(1));
      expect(repository.apiKeys, isEmpty);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionIdle>(),
      );
    },
  );

  test('disposing while a displaced verified repository closes does not publish stale success', () async {
    final firstAuthority = NormalizedAuthority.parse('https://first.example');
    final secondAuthority = NormalizedAuthority.parse('https://second.example');
    final store = InMemoryPinStore();
    await _seed(store, firstAuthority, _digest);
    await _seed(store, secondAuthority, _digest);
    final firstTransport = _CountingTransport();
    final secondTransport = _CountingTransport();
    final firstClose = Completer<void>();
    late _HeldCloseRepository firstRepository;
    late _HeldCloseRepository secondRepository;
    var repositoryCount = 0;
    final container = _nativeContainer(
      store: store,
      probe: _AuthorityProbe(<String>[]),
      connector: _SequenceConnector([
        NativePinnedVerified(firstTransport),
        NativePinnedVerified(secondTransport),
      ]),
      factory: ({required connector, required credentialVault}) {
        repositoryCount++;
        return repositoryCount == 1
            ? firstRepository = _HeldCloseRepository(
                connector,
                closeGate: firstClose.future,
              )
            : secondRepository = _HeldCloseRepository(connector);
      },
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);

    await controller.connect(
      serverInput: 'https://first.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    expect(
      container.read(serverProfilesControllerProvider).profiles,
      hasLength(1),
    );

    final second = controller.connect(
      serverInput: 'https://second.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await firstRepository.closeStarted.future;
    container.invalidate(connectionControllerProvider);
    firstClose.complete();
    await second;

    expect(
      container.read(serverProfilesControllerProvider).profiles,
      hasLength(1),
    );
    expect(container.read(connectionControllerProvider), isA<ConnectionIdle>());
    expect(firstRepository.closeCalls, 1);
    expect(secondRepository.closeCalls, 1);
    expect(firstTransport.closeCalls, 1);
    expect(secondTransport.closeCalls, 1);
  });

  test(
    'synchronous route provider failure is safe and later connect recovers',
    () async {
      var fail = true;
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWith((ref) {
            if (fail) throw StateError(_sentinel);
            return TlsTrustRoute.platformValidated;
          }),
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>(),
      );
      fail = false;
      container.invalidate(tlsTrustRouteProvider);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionSucceeded>(),
      );
    },
  );

  test(
    'native public certificate cancels trust work before normal authentication',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final events = <String>[];
      final repository = _Repository(events: events);
      final container = _nativeContainer(
        store: _RecordingStore(events),
        probe: _Probe(
          _certificate(authority, PlatformTrust.passed),
          events: events,
        ),
        connector: _Connector(
          NativePinnedVerified(_Transport()),
          events: events,
        ),
        normal: repository,
      );
      addTearDown(container.dispose);
      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );
      expect(repository.apiKeys, [_sentinel]);
      expect(
        events.indexOf('cancel'),
        lessThan(events.indexOf('repositoryAuth')),
      );
    },
  );

  test(
    'visible review can switch to browser route without remaining busy',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      var route = TlsTrustRoute.native;
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWith((ref) => route),
          certificateTrustCoordinatorProvider.overrideWithValue(
            _coordinator(
              authority: authority,
              platformTrust: PlatformTrust.didNotPass,
              transport: _Transport(),
            ),
          ),
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      route = TlsTrustRoute.browserManaged;
      container.invalidate(tlsTrustRouteProvider);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionBrowserManagedTls>(),
      );
      route = TlsTrustRoute.platformValidated;
      container.invalidate(tlsTrustRouteProvider);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(repository.apiKeys, [_sentinel]);
    },
  );

  test(
    'cancelTrust publishes cancelled blocked state with visible token',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final repository = _Repository();
      final container = _nativeContainer(
        store: InMemoryPinStore(),
        probe: _Probe(_certificate(authority)),
        connector: _Connector(NativePinnedVerified(_Transport())),
        normal: repository,
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      final review = container.read(
        connectionControllerProvider,
      ) as ConnectionFirstTrustReview;
      await controller.cancelTrust();
      final blocked = container.read(
        connectionControllerProvider,
      ) as ConnectionTrustBlocked;
      expect(blocked.failure, CertificateTrustCoordinatorFailure.cancelled);
      expect(blocked.token, same(review.token));
      expect(blocked.authority, authority);
      expect(repository.apiKeys, isEmpty);
    },
  );

  test('approve action exception leaves a safe failure and a later normal connect works', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final container = _nativeContainer(
      store: _ThrowStageStore(),
      probe: _Probe(_certificate(authority)),
      connector: _Connector(NativePinnedVerified(_Transport())),
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await controller.approveTrust(apiKey: _sentinel, username: 'test-account');
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionTrustBlocked>(),
    );
  });

  test('retry without an explicit key attempts remembered credentials and closes when missing', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final transport = _CountingTransport();
    final store = InMemoryPinStore();
    final container = _nativeContainer(
      store: store,
      probe: _Probe(_certificate(authority)),
      connector: _Connector(NativePinnedVerified(transport)),
      credentialVault: const NoopCredentialVault(),
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await controller.cancelTrust();
    final blocked =
        container.read(connectionControllerProvider) as ConnectionTrustBlocked;
    expect(blocked.failure, CertificateTrustCoordinatorFailure.cancelled);
    await _seed(store, authority, _digest);

    await controller.retryTrust(username: 'test-account');

    final retried = container.read(connectionControllerProvider);
    expect(
      retried,
      isA<ConnectionFailed>().having(
        (state) => state.message,
        'message',
        'An API key is required to connect to this server.',
      ),
    );
    expect(transport.closeCalls, 1);
  });

  test('retry without a key contains close failure and resets busy', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final transport = _ThrowingCloseTransport();
    final store = InMemoryPinStore();
    final container = _nativeContainer(
      store: store,
      probe: _Probe(_certificate(authority)),
      connector: _Connector(NativePinnedVerified(transport)),
      credentialVault: const NoopCredentialVault(),
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await controller.cancelTrust();
    await _seed(store, authority, _digest);

    await controller.retryTrust(username: 'test-account');

    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionFailed>().having(
        (state) => state.message,
        'message',
        'An API key is required to connect to this server.',
      ),
    );
    expect(transport.closeCalls, 1);
    await controller.connect(
      serverInput: 'not a server',
      apiKey: _sentinel,
      username: 'test-account',
    );
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionFailed>(),
    );
  });

  test(
    'repository factory failure closes unconsumed verified transport',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final transport = _CountingTransport();
      final container = _nativeContainer(
        store: InMemoryPinStore(),
        probe: _Probe(_certificate(authority)),
        connector: _Connector(NativePinnedVerified(transport)),
        factory: ({required connector, required credentialVault}) =>
            throw StateError('factory'),
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      await controller.approveTrust(
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>(),
      );
      expect(transport.closeCalls, 1);
    },
  );

  test(
    'wrong repository connector endpoint closes the verified transport once',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final transport = _CountingTransport();
      late _Repository repository;
      final container = _nativeContainer(
        store: InMemoryPinStore(),
        probe: _Probe(_certificate(authority)),
        connector: _Connector(NativePinnedVerified(transport)),
        factory: ({required connector, required credentialVault}) =>
            repository = _Repository(connector: connector, wrongEndpoint: true),
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      await controller.approveTrust(
        apiKey: _sentinel,
        username: 'test-account',
        rememberApiKey: true,
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>(),
      );
      expect(transport.closeCalls, 1);
      expect(repository.closeCalls, 1);
      expect(repository.rememberApiKeyIntents, [true]);
    },
  );

  test(
    'browser route is lazy when factory and credential vault throw',
    () async {
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.browserManaged),
          sessionRepositoryFactoryProvider.overrideWith(
            (ref) =>
                ({required connector, required credentialVault}) =>
                    throw StateError('factory'),
          ),
          credentialVaultProvider.overrideWith(
            (ref) => throw StateError('vault'),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
            rememberApiKey: true,
          );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionBrowserManagedTls>(),
      );
    },
  );

  test('cancel action synchronous exception becomes safe failure and later connect works', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    var throwCoordinator = false;
    var route = TlsTrustRoute.native;
    final repository = _Repository();
    final coordinator = _coordinator(
      authority: authority,
      platformTrust: PlatformTrust.didNotPass,
      transport: _Transport(),
    );
    final container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWith((ref) => route),
        certificateTrustCoordinatorProvider.overrideWith((ref) {
          if (throwCoordinator) throw StateError('cancel seam');
          return coordinator;
        }),
        sessionRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    throwCoordinator = true;
    container.invalidate(certificateTrustCoordinatorProvider);
    await controller.cancelTrust();
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionFailed>(),
    );

    throwCoordinator = false;
    route = TlsTrustRoute.platformValidated;
    container.invalidate(tlsTrustRouteProvider);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionSucceeded>(),
    );
    expect(repository.apiKeys, [_sentinel]);
  });

  test('retry action synchronous exception becomes safe failure and later connect works', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    var throwCoordinator = false;
    var route = TlsTrustRoute.native;
    final repository = _Repository();
    final coordinator = _coordinator(
      authority: authority,
      platformTrust: PlatformTrust.didNotPass,
      transport: _Transport(),
    );
    final container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWith((ref) => route),
        certificateTrustCoordinatorProvider.overrideWith((ref) {
          if (throwCoordinator) throw StateError('retry seam');
          return coordinator;
        }),
        sessionRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await controller.cancelTrust();
    throwCoordinator = true;
    container.invalidate(certificateTrustCoordinatorProvider);
    await controller.retryTrust(username: 'test-account');
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionFailed>(),
    );

    throwCoordinator = false;
    route = TlsTrustRoute.platformValidated;
    container.invalidate(tlsTrustRouteProvider);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionSucceeded>(),
    );
    expect(repository.apiKeys, [_sentinel]);
  });

  test(
    'same-authority action while probe is busy does not duplicate work',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final probe = _DelayedProbe();
      final container = _nativeContainer(
        store: InMemoryPinStore(),
        probe: probe,
        connector: _Connector(NativePinnedVerified(_Transport())),
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      final first = controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      final second = controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      await Future<void>.delayed(Duration.zero);
      expect(probe.calls, 1);
      probe.complete(_certificate(authority));
      await Future.wait([first, second]);
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFirstTrustReview>(),
      );
    },
  );

  test('retry from cancelled operation creates a fresh review token without credentials', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final repository = _Repository();
    final container = _nativeContainer(
      store: InMemoryPinStore(),
      probe: _Probe(_certificate(authority)),
      connector: _Connector(NativePinnedVerified(_Transport())),
      normal: repository,
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    final first = container.read(
      connectionControllerProvider,
    ) as ConnectionFirstTrustReview;
    await controller.cancelTrust();
    await controller.retryTrust(username: 'test-account');
    final fresh = container.read(
      connectionControllerProvider,
    ) as ConnectionFirstTrustReview;
    expect(fresh.token, isNot(same(first.token)));
    expect(repository.apiKeys, isEmpty);
  });

  test(
    'repository-owned transport is closed once after authentication failure',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final transport = _CountingTransport();
      late _Repository repository;
      final container = _nativeContainer(
        store: InMemoryPinStore(),
        probe: _Probe(_certificate(authority)),
        connector: _Connector(NativePinnedVerified(transport)),
        factory: ({required connector, required credentialVault}) =>
            repository = _Repository(
              connector: connector,
              error: const AuthenticationStateException(
                AuthenticationState.authenticationFailed,
              ),
              closeConsumedTransport: true,
            ),
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      await controller.approveTrust(
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>(),
      );
      expect(repository.closeCalls, 1);
      expect(transport.closeCalls, 1);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
    },
  );

  test('verified repository consumes connector once, profiles once, and adapter does not close it', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final transport = _CountingTransport();
    late _Repository repository;
    final container = _nativeContainer(
      store: InMemoryPinStore(),
      probe: _Probe(_certificate(authority)),
      connector: _Connector(NativePinnedVerified(transport)),
      factory: ({required connector, required credentialVault}) =>
          repository = _Repository(connector: connector),
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await controller.approveTrust(apiKey: _sentinel, username: 'test-account');
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionSucceeded>(),
    );
    expect(
      container.read(serverProfilesControllerProvider).profiles,
      hasLength(1),
    );
    expect(repository.connectorCalls, 1);
    await expectLater(
      repository.connector!.connect(authority.rpcConnectionUri),
      throwsStateError,
    );
    expect(transport.closeCalls, 0);
  });

  test(
    'changing authority cancels visible review before starting new probe',
    () async {
      final newAuthority = NormalizedAuthority.parse('https://new.example');
      final events = <String>[];
      final container = _nativeContainer(
        store: _RecordingStore(events),
        probe: _AuthorityProbe(events),
        connector: _Connector(
          NativePinnedVerified(_Transport()),
          events: events,
        ),
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);
      await controller.connect(
        serverInput: 'https://old.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      final old = container.read(
        connectionControllerProvider,
      ) as ConnectionFirstTrustReview;
      await controller.connect(
        serverInput: 'https://new.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      final replacement = container.read(
        connectionControllerProvider,
      ) as ConnectionFirstTrustReview;
      expect(replacement.token, isNot(same(old.token)));
      expect(replacement.authority, newAuthority);
      expect(events.where((event) => event == 'probe'), hasLength(2));
    },
  );

  test(
    'factory-triggered disposal cannot hand a key to stale authentication',
    () async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final transport = _CountingTransport();
      late _Repository repository;
      late ProviderContainer container;
      container = _nativeContainer(
        store: InMemoryPinStore(),
        probe: _Probe(_certificate(authority)),
        connector: _Connector(NativePinnedVerified(transport)),
        factory: ({required connector, required credentialVault}) {
          container.invalidate(connectionControllerProvider);
          return repository = _Repository(connector: connector, consume: false);
        },
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);

      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      await controller.approveTrust(
        apiKey: _sentinel,
        username: 'test-account',
      );

      expect(repository.apiKeys, isEmpty);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionIdle>(),
      );
      expect(transport.closeCalls, 1);
      expect(repository.closeCalls, 1);
    },
  );

  test('production normal provider owns a stale repository disposed during composition', () async {
    final repository = _Repository();
    late ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWithValue(
          TlsTrustRoute.platformValidated,
        ),
        sessionRepositoryFactoryProvider.overrideWithValue(({
          required connector,
          required credentialVault,
        }) {
          container.invalidate(connectionControllerProvider);
          return repository;
        }),
      ],
    );
    final controller = container.read(connectionControllerProvider.notifier);

    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );

    expect(repository.apiKeys, isEmpty);
    expect(container.read(serverProfilesControllerProvider).profiles, isEmpty);
    expect(container.read(connectionControllerProvider), isA<ConnectionIdle>());
    expect(repository.closeCalls, 0);
    container.dispose();
    expect(repository.closeCalls, 1);
  });

  test(
    'production normal provider closes a successful repository exactly once',
    () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(
            TlsTrustRoute.platformValidated,
          ),
          sessionRepositoryFactoryProvider.overrideWithValue(
            ({required connector, required credentialVault}) => repository,
          ),
        ],
      );
      final controller = container.read(connectionControllerProvider.notifier);

      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );

      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionSucceeded>(),
      );
      expect(repository.apiKeys, [_sentinel]);
      expect(repository.closeCalls, 0);
      container.dispose();
      expect(repository.closeCalls, 1);
    },
  );

  test('successful pinned authentication replaces and closes the active normal repository', () async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final normal = _QueryingRepository();
    late _Repository verified;
    final store = InMemoryPinStore();
    await _seed(store, authority, _digest);
    var route = TlsTrustRoute.platformValidated;
    var factoryCalls = 0;
    final container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWith((ref) => route),
        certificateTrustCoordinatorProvider.overrideWithValue(
          CertificateTrustCoordinator(
            pinStore: store,
            probe: _Probe(_certificate(authority)),
            connector: _Connector(NativePinnedVerified(_Transport())),
            now: () => DateTime.utc(2026, 2),
            probeTimeout: const Duration(seconds: 1),
            reconnectTimeout: const Duration(seconds: 1),
          ),
        ),
        sessionRepositoryFactoryProvider.overrideWithValue(({
          required connector,
          required credentialVault,
        }) {
          if (++factoryCalls == 1) return normal;
          return verified = _Repository(connector: connector);
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);

    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await container.read(dashboardLoadProvider('home').future);
    expect(normal.queriedMethods, ['system.info']);
    expect(normal.closeCalls, 0);

    route = TlsTrustRoute.native;
    container.invalidate(tlsTrustRouteProvider);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );

    expect(normal.closeCalls, 1);
    expect(verified.closeCalls, 0);
    expect(
      container.read(activeAuthenticatedSessionProvider)!.repository,
      same(verified),
    );
  });

  test('production normal provider replaces invalidated repository for a live controller', () async {
    final first = _Repository();
    final second = _Repository();
    var factoryCalls = 0;
    final container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWithValue(
          TlsTrustRoute.platformValidated,
        ),
        sessionRepositoryFactoryProvider.overrideWithValue(({
          required connector,
          required credentialVault,
        }) {
          factoryCalls++;
          return factoryCalls == 1 ? first : second;
        }),
      ],
    );
    final controller = container.read(connectionControllerProvider.notifier);

    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionSucceeded>(),
    );
    expect(factoryCalls, 1);
    expect(first.apiKeys, [_sentinel]);

    container.invalidate(sessionRepositoryProvider);
    expect(first.closeCalls, 1);

    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );

    expect(factoryCalls, 2);
    expect(first.apiKeys, [_sentinel]);
    expect(second.apiKeys, [_sentinel]);
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionSucceeded>(),
    );
    expect(second.closeCalls, 0);

    container.dispose();
    expect(second.closeCalls, 1);
  });

  test(
    'a new normal attempt suspends dashboard and uses a fresh repository',
    () async {
      final first = _QueryingRepository();
      final second = _PendingRepository();
      var factoryCalls = 0;
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(
            TlsTrustRoute.platformValidated,
          ),
          sessionRepositoryFactoryProvider.overrideWithValue(
            ({required connector, required credentialVault}) =>
                ++factoryCalls == 1 ? first : second,
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);

      await controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      expect(container.read(dashboardRepositoryProvider), isNotNull);
      await container.read(dashboardLoadProvider('home').future);
      expect(first.queriedMethods, ['system.info']);

      final retry = controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );

      expect(container.read(dashboardRepositoryProvider), isNull);
      expect(container.read(activeAuthenticatedSessionProvider), isNull);
      await second.started.future;
      expect(factoryCalls, 2);
      expect(first.closeCalls, 1);

      second.fail(StateError('second handshake failed'));
      await retry;

      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionFailed>(),
      );
      expect(container.read(dashboardRepositoryProvider), isNull);
      expect(container.read(activeAuthenticatedSessionProvider), isNull);
      expect(first.closeCalls, 1);
    },
  );

  test(
    'invalidating the normal repository abandons its pending authentication',
    () async {
      final first = _PendingRepository();
      final second = _Repository();
      var factoryCalls = 0;
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(
            TlsTrustRoute.platformValidated,
          ),
          sessionRepositoryFactoryProvider.overrideWithValue(
            ({required connector, required credentialVault}) =>
                ++factoryCalls == 1 ? first : second,
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(connectionControllerProvider.notifier);

      final connecting = controller.connect(
        serverInput: 'https://nas.example',
        apiKey: _sentinel,
        username: 'test-account',
      );
      await first.started.future;
      expect(first.apiKeys, [_sentinel]);

      container.invalidate(sessionRepositoryProvider);
      expect(first.closeCalls, 1);

      first.succeed();
      await connecting;

      expect(
        container.read(connectionControllerProvider),
        isNot(isA<ConnectionSucceeded>()),
      );
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
      expect(first.apiKeys, [_sentinel]);
      expect(second.apiKeys, isEmpty);
    },
  );

  test('normal lease refresh failure abandons pending authentication and permits retry', () async {
    final first = _PendingRepository();
    final healthy = _Repository();
    var factoryCalls = 0;
    var replacementFails = true;
    final container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWithValue(
          TlsTrustRoute.platformValidated,
        ),
        sessionRepositoryFactoryProvider.overrideWithValue(({
          required connector,
          required credentialVault,
        }) {
          factoryCalls++;
          if (factoryCalls == 1) return first;
          if (replacementFails) throw StateError('replacement factory');
          return healthy;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);

    final connecting = controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );
    await first.started.future;
    container.invalidate(sessionRepositoryProvider);
    expect(first.closeCalls, 1);

    first.succeed();
    await connecting;

    expect(factoryCalls, 2);
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionFailed>(),
    );
    expect(
      '${container.read(connectionControllerProvider)}',
      isNot(contains(_sentinel)),
    );
    expect(container.read(serverProfilesControllerProvider).profiles, isEmpty);
    expect(first.apiKeys, [_sentinel]);
    expect(healthy.apiKeys, isEmpty);

    replacementFails = false;
    container.invalidate(sessionRepositoryProvider);
    await controller.connect(
      serverInput: 'https://nas.example',
      apiKey: _sentinel,
      username: 'test-account',
    );

    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionSucceeded>(),
    );
    expect(factoryCalls, 3);
    expect(healthy.apiKeys, [_sentinel]);
    expect(healthy.closeCalls, 0);
    container.dispose();
    expect(first.closeCalls, 1);
    expect(healthy.closeCalls, 1);
  });

  test(
    'normal repository close failures are contained during invalidation',
    () async {
      final repository = _ThrowingCloseRepository();
      final container = ProviderContainer(
        overrides: [
          sessionRepositoryFactoryProvider.overrideWithValue(
            ({required connector, required credentialVault}) => repository,
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(sessionRepositoryProvider);
      container.invalidate(sessionRepositoryProvider);
      await Future<void>.delayed(Duration.zero);

      expect(repository.closeCalls, 1);
    },
  );

  test(
    'profile provider initialization cannot publish a stale profile or success',
    () async {
      final repository = _Repository();
      final observer = _InvalidateConnectionOnFirstProfileProviderAdd();
      final container = ProviderContainer(
        observers: [observer],
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(
            TlsTrustRoute.platformValidated,
          ),
          sessionRepositoryFactoryProvider.overrideWithValue(
            ({required connector, required credentialVault}) => repository,
          ),
        ],
      );

      await container
          .read(connectionControllerProvider.notifier)
          .connect(
            serverInput: 'https://nas.example',
            apiKey: _sentinel,
            username: 'test-account',
          );

      expect(observer.didInvalidate, isTrue);
      expect(repository.apiKeys, [_sentinel]);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionIdle>(),
      );
      expect(repository.closeCalls, 0);
      container.dispose();
      expect(repository.closeCalls, 1);
    },
  );
}

final class _InvalidateConnectionOnFirstProfileProviderAdd
    extends ProviderObserver {
  var didInvalidate = false;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (didInvalidate || context.provider != serverProfilesControllerProvider) {
      return;
    }
    didInvalidate = true;
    context.container.invalidate(connectionControllerProvider);
  }
}

CertificateTrustCoordinator _coordinator({
  required NormalizedAuthority authority,
  required PlatformTrust platformTrust,
  required RpcTransport transport,
}) => CertificateTrustCoordinator(
  pinStore: InMemoryPinStore(),
  probe: _Probe(
    NativeProbeCertificate(
      PresentedCertificate(
        namesAuthority: true,
        authority: authority,
        platformTrust: platformTrust,
        facts: CertificateFacts(
          subjectSummary: 'nas.example',
          issuerSummary: 'Test issuer',
          leafDerSha256: _digest,
          notValidBefore: DateTime.utc(2026),
          notValidAfter: DateTime.utc(2027),
        ),
      ),
    ),
  ),
  connector: _Connector(NativePinnedVerified(transport)),
  now: () => DateTime.utc(2026, 2),
  probeTimeout: const Duration(seconds: 1),
  reconnectTimeout: const Duration(seconds: 1),
);

final class _Probe implements NativeCertificateProbe {
  _Probe(this.outcome, {this.events});
  final NativeProbeOutcome outcome;
  final List<String>? events;
  var calls = 0;
  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    calls++;
    events?.add('probe');
    return outcome;
  }
}

final class _AuthorityProbe implements NativeCertificateProbe {
  _AuthorityProbe(this.events);

  final List<String> events;
  var calls = 0;

  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    calls++;
    events.add('probe');
    return _certificate(authority);
  }
}

final class _Connector implements PinnedRpcConnector {
  _Connector(this.outcome, {this.events});
  final NativePinnedOutcome outcome;
  final List<String>? events;
  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    events?.add('reconnect');
    return outcome;
  }
}

final class _SequenceConnector implements PinnedRpcConnector {
  _SequenceConnector(this._outcomes, {this.events});
  final List<NativePinnedOutcome> _outcomes;
  final List<String>? events;
  var _index = 0;

  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    events?.add('reconnect');
    return _outcomes[_index++];
  }
}

final class _DelayedConnector implements PinnedRpcConnector {
  final started = Completer<void>();
  final _result = Completer<NativePinnedOutcome>();

  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    started.complete();
    return _result.future;
  }

  void complete(NativePinnedOutcome outcome) => _result.complete(outcome);
}

class _Transport implements RpcTransport {
  @override
  Stream<String> get inboundFrames => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  Future<void> send(String frame) async {}
}

final class _CountingTransport extends _Transport {
  var closeCalls = 0;
  @override
  Future<void> close() async {
    closeCalls++;
  }
}

final class _ThrowingCloseTransport extends _Transport {
  var closeCalls = 0;
  @override
  Future<void> close() async {
    closeCalls++;
    throw StateError('close');
  }
}

final class _DelayedProbe implements NativeCertificateProbe {
  final _result = Completer<NativeProbeOutcome>();
  var calls = 0;

  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) {
    calls++;
    return _result.future;
  }

  void complete(NativeProbeOutcome outcome) => _result.complete(outcome);
}

class _Repository implements SessionRepository {
  _Repository({
    this.connector,
    this.error,
    this.consume = true,
    this.closeConsumedTransport = false,
    this.wrongEndpoint = false,
    this.events,
  });
  final RpcConnector? connector;
  final Object? error;
  final bool consume;
  final bool closeConsumedTransport;
  final bool wrongEndpoint;
  final List<String>? events;
  final apiKeys = <String>[];
  final rememberApiKeyIntents = <bool>[];
  final connectedEndpoints = <Uri>[];
  var closeCalls = 0;
  var connectorCalls = 0;
  RpcTransport? _consumedTransport;
  @override
  Future<void> close() async {
    closeCalls++;
    final transport = _consumedTransport;
    _consumedTransport = null;
    if (closeConsumedTransport && transport != null) await transport.close();
  }

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async {
    apiKeys.add(apiKey ?? '');
    rememberApiKeyIntents.add(rememberApiKey);
    events?.add('repositoryAuth');
    final endpoint = Uri.parse(serverInput);
    connectedEndpoints.add(endpoint);
    if (connector != null && consume) {
      connectorCalls++;
      _consumedTransport = await connector!.connect(
        wrongEndpoint ? Uri.parse('wss://other.example/websocket') : endpoint,
      );
    }
    if (error != null) throw error!;
    return ServerSummary(
      originalHostInput: serverInput,
      endpointUri: endpoint,
      identity: 'admin',
      version: '1',
      availableMethodNames: const {},
    );
  }
}

final class _QueryingRepository extends _Repository
    implements AuthenticatedSessionQueries {
  final queriedMethods = <String>[];

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async {
    final summary = await super.connect(
      serverInput: serverInput,
      apiKey: apiKey,
      username: username,
      rememberApiKey: rememberApiKey,
      isConnectionCurrent: isConnectionCurrent,
    );
    return ServerSummary(
      originalHostInput: summary.originalHostInput,
      endpointUri: summary.endpointUri,
      identity: summary.identity,
      version: summary.version,
      availableMethodNames: const {'system.info'},
    );
  }

  @override
  Future<Object?> query(String method) async {
    queriedMethods.add(method);
    return <String, Object?>{'hostname': 'nas', 'version': '1'};
  }
}

final class _PendingRepository extends _Repository {
  final started = Completer<void>();
  final _result = Completer<ServerSummary>();

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) {
    apiKeys.add(apiKey ?? '');
    rememberApiKeyIntents.add(rememberApiKey);
    started.complete();
    return _result.future;
  }

  void succeed() => _result.complete(
    ServerSummary(
      originalHostInput: 'https://nas.example',
      endpointUri: Uri.parse('wss://nas.example/websocket'),
      identity: 'admin',
      version: '1',
      availableMethodNames: const {},
    ),
  );

  void fail(Object error) => _result.completeError(error);
}

final class _ThrowingCloseRepository extends _Repository {
  @override
  Future<void> close() async {
    closeCalls++;
    await Future<void>.delayed(Duration.zero);
    throw StateError('close');
  }
}

final class _DelayedRepository implements SessionRepository {
  _DelayedRepository(this.connector);
  final RpcConnector connector;
  final started = Completer<void>();
  final _summary = Completer<ServerSummary>();
  RpcTransport? _transport;
  var closeCalls = 0;

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async {
    _transport = await connector.connect(Uri.parse(serverInput));
    started.complete();
    return _summary.future;
  }

  void complete() => _summary.complete(
    ServerSummary(
      originalHostInput: 'https://nas.example',
      endpointUri: Uri.parse('wss://nas.example/api/current'),
      identity: 'admin',
      version: '1',
      availableMethodNames: const {},
    ),
  );

  @override
  Future<void> close() async {
    closeCalls++;
    final transport = _transport;
    _transport = null;
    await transport?.close();
  }
}

final class _HeldCloseRepository implements SessionRepository {
  _HeldCloseRepository(this.connector, {this.closeGate});

  final RpcConnector connector;
  final Future<void>? closeGate;
  final closeStarted = Completer<void>();
  RpcTransport? _transport;
  var closeCalls = 0;

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async {
    final endpoint = Uri.parse(serverInput);
    _transport = await connector.connect(endpoint);
    return ServerSummary(
      originalHostInput: serverInput,
      endpointUri: endpoint,
      identity: 'admin',
      version: '1',
      availableMethodNames: const {},
    );
  }

  @override
  Future<void> close() async {
    closeCalls++;
    closeStarted.complete();
    await closeGate;
    final transport = _transport;
    _transport = null;
    await transport?.close();
  }
}

NativeProbeCertificate _certificate(
  NormalizedAuthority authority, [
  PlatformTrust trust = PlatformTrust.didNotPass,
]) => NativeProbeCertificate(
  PresentedCertificate(
    namesAuthority: true,
    authority: authority,
    platformTrust: trust,
    facts: CertificateFacts(
      subjectSummary: 'nas.example',
      issuerSummary: 'issuer',
      leafDerSha256: _digest,
      notValidBefore: DateTime.utc(2026),
      notValidAfter: DateTime.utc(2027),
    ),
  ),
);

Future<void> _seed(
  PinStore store,
  NormalizedAuthority authority,
  String digest,
) async {
  final staged = await store.stageReplacement(
    authority,
    PinRecord(leafDerSha256: digest, createdAt: DateTime.utc(2026)),
  );
  await (staged as PinStageSuccess).transaction.commit();
}

ProviderContainer _nativeContainer({
  required PinStore store,
  required NativeCertificateProbe probe,
  required PinnedRpcConnector connector,
  SessionRepository? normal,
  SessionRepositoryFactory? factory,
  CredentialVault? credentialVault,
}) => ProviderContainer(
  overrides: [
    tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
    certificateTrustCoordinatorProvider.overrideWithValue(
      CertificateTrustCoordinator(
        pinStore: store,
        probe: probe,
        connector: connector,
        now: () => DateTime.utc(2026, 2),
        probeTimeout: const Duration(seconds: 1),
        reconnectTimeout: const Duration(seconds: 1),
      ),
    ),
    if (normal != null) sessionRepositoryProvider.overrideWithValue(normal),
    if (factory != null)
      sessionRepositoryFactoryProvider.overrideWithValue(factory),
    if (credentialVault != null)
      credentialVaultProvider.overrideWithValue(credentialVault),
  ],
);

final class _RecordingStore implements PinStore {
  _RecordingStore(this.events);
  final List<String> events;
  final _inner = InMemoryPinStore();
  @override
  Future<PinReadResult> read(NormalizedAuthority authority) async {
    events.add('read');
    return _inner.read(authority);
  }

  @override
  Future<PinRecoveryResult> recoverReplacement(
    NormalizedAuthority authority,
  ) async {
    events.add('recover');
    return _inner.recoverReplacement(authority);
  }

  @override
  Future<PinStageResult> stageReplacement(
    NormalizedAuthority authority,
    PinRecord replacement,
  ) => _inner.stageReplacement(authority, replacement);
}

final class _EventStore implements PinStore {
  _EventStore(this.events);
  final List<String> events;
  final _inner = InMemoryPinStore();

  @override
  Future<PinReadResult> read(NormalizedAuthority authority) =>
      _inner.read(authority);

  @override
  Future<PinRecoveryResult> recoverReplacement(NormalizedAuthority authority) =>
      _inner.recoverReplacement(authority);

  @override
  Future<PinStageResult> stageReplacement(
    NormalizedAuthority authority,
    PinRecord replacement,
  ) async {
    final result = await _inner.stageReplacement(authority, replacement);
    return switch (result) {
      PinStageSuccess(:final transaction) => PinStageResult.success(
        _EventTransaction(transaction, events),
      ),
      PinStageFailure(:final failure) => PinStageResult.failure(failure),
    };
  }
}

final class _EventTransaction implements PinStoreTransaction {
  const _EventTransaction(this._inner, this._events);
  final PinStoreTransaction _inner;
  final List<String> _events;

  @override
  Future<PinStoreResult> abort() => _inner.abort();

  @override
  Future<PinStoreResult> commit() async {
    final result = await _inner.commit();
    _events.add('commit');
    return result;
  }
}

final class _ThrowStageStore implements PinStore {
  final _inner = InMemoryPinStore();
  @override
  Future<PinReadResult> read(NormalizedAuthority authority) =>
      _inner.read(authority);
  @override
  Future<PinRecoveryResult> recoverReplacement(NormalizedAuthority authority) =>
      _inner.recoverReplacement(authority);
  @override
  Future<PinStageResult> stageReplacement(
    NormalizedAuthority authority,
    PinRecord replacement,
  ) => throw StateError('stage');
}

final class _Vault implements CredentialVault {
  var calls = 0;
  @override
  Future<void> deleteApiKey(String endpointIdentifier) async => calls++;
  @override
  Future<String?> readApiKey(String endpointIdentifier) async {
    calls++;
    return null;
  }

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async => calls++;
}
