import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/connection/connection_screen.dart';
import 'package:truenavo/features/connection/connection_state.dart';
import 'package:truenavo/features/server_profiles/server_profiles_controller.dart';
import 'package:truenavo/features/tls_trust/certificate_facts.dart';
import 'package:truenavo/features/tls_trust/certificate_trust_coordinator.dart';
import 'package:truenavo/features/tls_trust/models.dart';
import 'package:truenavo/features/tls_trust/native_tls_ports.dart';
import 'package:truenavo/features/tls_trust/pin_store.dart';
import 'package:truenavo/features/tls_trust/tls_trust_providers.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _password = ' synthetic password with spaces ';
const _apiKey = 'synthetic-key-never-forwarded';
const _endpoint = 'wss://nas.example/api/current';
const _digest =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final _authority = NormalizedAuthority.parse('https://nas.example');

void main() {
  testWidgets(
    'switching API-key certificate review to password still cancels OTP on screen disposal',
    (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _pump(tester, h);
      await _fillApiKey(tester);
      await _tap(tester, 'connect-button');
      expect(h.state, isA<ConnectionFirstTrustReview>());
      expect(h.repositories, isEmpty);
      await _passwordMode(tester);
      await _tap(tester, 'approve-trust-button');
      expect(h.state, isA<ConnectionOtpRequired>());
      final repository = h.repositories.single;
      expect(repository.passwords, [_password]);
      expect(repository.keyCalls, 0);
      expect(repository.tokens, isEmpty);
      await _pump(tester, h, showScreen: false);
      expect(repository.tokens, [null]);
      expect(repository.closeCalls, greaterThan(0));
      expect(h.controller.activeSession, isNull);
      expect(h.state, isA<ConnectionFailed>());
      expect(
        h.container.read(serverProfilesControllerProvider).selectedProfile,
        isNull,
      );
    },
  );

  testWidgets(
    'switching API-key blocked pinned retry to password cancels OTP on screen disposal',
    (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.seedPin();
      h.connector.outcomes.add(
        const NativePinnedBoundaryFailure(
          NativeTlsBoundaryFailure.backendFailure,
        ),
      );
      await _pump(tester, h);
      await _fillApiKey(tester);
      await _tap(tester, 'connect-button');
      expect(h.state, isA<ConnectionTrustBlocked>());
      expect(h.repositories, isEmpty);
      await _passwordMode(tester);
      await _tap(tester, 'retry-trust-button');
      expect(h.state, isA<ConnectionOtpRequired>());
      final repository = h.repositories.single;
      expect(repository.passwords, [_password]);
      await _pump(tester, h, showScreen: false);
      expect(repository.tokens, [null]);
      expect(repository.closeCalls, greaterThan(0));
      expect(h.controller.activeSession, isNull);
      expect(h.state, isA<ConnectionFailed>());
      expect(
        h.container.read(serverProfilesControllerProvider).selectedProfile,
        isNull,
      );
    },
  );

  test('password and OTP are withheld until approved pinned transport and use one endpoint-bound channel', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.connectPassword();
    expect(h.state, isA<ConnectionFirstTrustReview>());
    expect(h.repositories, isEmpty);
    expect(h.normal.keyCalls, 0);
    expect(h.normal.passwords, isEmpty);
    final pinned = Completer<NativePinnedOutcome>();
    h.connector.delayed = pinned;
    final approving = h.controller.approveTrust(
      apiKey: _apiKey,
      username: 'alice',
      password: _password,
      rememberApiKey: true,
    );
    await _turns();
    expect(h.connector.calls, 1);
    expect(h.repositories, isEmpty);
    final transport = _Transport();
    pinned.complete(NativePinnedVerified(transport));
    await _turns();
    expect(h.state, isA<ConnectionOtpRequired>());
    final repository = h.repositories.single;
    expect(repository.passwords, [_password]);
    expect(repository.consumed, same(transport));
    expect(repository.endpoints, [Uri.parse(_endpoint)]);
    expect(repository.keyCalls, 0);
    final challenge = (h.state as ConnectionOtpRequired).challenge;
    expect(challenge.endpoint, _endpoint);
    expect(h.controller.submitOtp(challenge, '123456'), isTrue);
    await approving;
    expect(repository.tokens, ['123456']);
    expect(h.controller.activeSession?.endpoint, _endpoint);
    expect(h.connector.calls, 1);
    await expectLater(
      repository.connector!.connect(Uri.parse(_endpoint)),
      throwsStateError,
    );
    await expectLater(
      repository.connector!.connect(
        Uri.parse('wss://other.example/api/current'),
      ),
      throwsStateError,
    );
  });

  test('cancelling password sign-in during delayed certificate probe withholds credentials and ignores late review', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final probe = Completer<NativeProbeOutcome>();
    h.probe.delayed = probe;
    final connecting = h.connectPassword();
    await _turns();
    expect(h.probe.calls, 1);
    expect(h.state, isA<ConnectionInProgress>());
    h.controller.cancelPasswordSignIn();
    expect(h.state, isA<ConnectionFailed>());
    probe.complete(_certificate());
    await connecting;
    expect(h.repositories, isEmpty);
    expect(h.connector.calls, 0);
    expect(h.state, isA<ConnectionFailed>());
    expect(h.controller.activeSession, isNull);
    expect(
      h.container.read(serverProfilesControllerProvider).selectedProfile,
      isNull,
    );
  });

  test('cancelling approved password sign-in during pinned reconnect closes late transport before credential handoff', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.connectPassword();
    final pinned = Completer<NativePinnedOutcome>();
    h.connector.delayed = pinned;
    final approving = h.controller.approveTrust(
      apiKey: null,
      username: 'alice',
      password: _password,
    );
    await _turns();
    expect(h.connector.calls, 1);
    h.controller.cancelPasswordSignIn();
    final transport = _Transport();
    pinned.complete(NativePinnedVerified(transport));
    await approving;
    expect(transport.closeCalls, 1);
    expect(h.repositories, isEmpty);
    expect(h.state, isA<ConnectionFailed>());
    expect(h.controller.activeSession, isNull);
  });

  test(
    'deferred disposal cancellation cannot overwrite a newer OTP attempt',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.connectPassword();
      final first = h.controller.approveTrust(
        apiKey: null,
        username: 'alice',
        password: _password,
      );
      await _turns();
      expect(h.state, isA<ConnectionOtpRequired>());
      final old = h.repositories.single;
      h.controller.cancelPasswordSignIn(deferState: true);
      final second = h.connectPassword();
      await _turns();
      await first;
      expect(h.repositories.length, 2);
      expect(old.tokens, [null]);
      expect(h.state, isA<ConnectionOtpRequired>());
      final challenge = (h.state as ConnectionOtpRequired).challenge;
      expect(h.controller.submitOtp(challenge, '654321'), isTrue);
      await second;
      expect(h.state, isA<ConnectionSucceeded>());
      expect(h.controller.activeSession?.repository, same(h.repositories.last));
      expect(h.repositories.last.tokens, ['654321']);
    },
  );

  testWidgets(
    'password and API-key inputs disable IME learning even while revealed',
    (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      await _pump(tester, h);
      final keyField = find.byKey(const Key('api-key-field'));
      expect(
        tester.widget<TextField>(keyField).enableIMEPersonalizedLearning,
        isFalse,
      );
      await _passwordMode(tester);
      final field = find.byKey(const Key('password-field'));
      expect(
        tester.widget<TextField>(field).enableIMEPersonalizedLearning,
        isFalse,
      );
      expect(tester.widget<TextField>(field).autocorrect, isFalse);
      expect(tester.widget<TextField>(field).enableSuggestions, isFalse);
      final reveal = find.byTooltip('Show Password');
      await tester.ensureVisible(reveal);
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).obscureText, isFalse);
      expect(
        tester.widget<TextField>(field).enableIMEPersonalizedLearning,
        isFalse,
      );
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Harness h, {
  bool showScreen = true,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        home: showScreen ? const ConnectionScreen() : const SizedBox.shrink(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _fillApiKey(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('server-url-field')),
    'https://nas.example',
  );
  await tester.enterText(find.byKey(const Key('username-field')), 'alice');
  await tester.enterText(find.byKey(const Key('api-key-field')), _apiKey);
}

Future<void> _passwordMode(WidgetTester tester) async {
  await _tap(tester, 'login-method-password');
  await tester.enterText(find.byKey(const Key('password-field')), _password);
}

Future<void> _turns() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Harness {
  _Harness() {
    coordinator = CertificateTrustCoordinator(
      pinStore: store,
      probe: probe,
      connector: connector,
      now: () => DateTime.utc(2026, 6),
      probeTimeout: const Duration(seconds: 10),
      reconnectTimeout: const Duration(seconds: 10),
    );
    container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
        certificateTrustCoordinatorProvider.overrideWithValue(coordinator),
        sessionRepositoryProvider.overrideWithValue(normal),
        sessionRepositoryFactoryProvider.overrideWithValue(({
          required connector,
          required credentialVault,
        }) {
          final repository = _PasswordRepository(connector: connector);
          repositories.add(repository);
          return repository;
        }),
      ],
    );
  }
  final store = InMemoryPinStore();
  final probe = _Probe();
  final connector = _PinnedConnector();
  final normal = _PasswordRepository();
  final repositories = <_PasswordRepository>[];
  late final CertificateTrustCoordinator coordinator;
  late final ProviderContainer container;
  ConnectionController get controller =>
      container.read(connectionControllerProvider.notifier);
  ConnectionState get state => container.read(connectionControllerProvider);
  Future<void> connectPassword() => controller.connect(
    serverInput: 'https://nas.example',
    apiKey: _apiKey,
    username: 'alice',
    password: _password,
    rememberApiKey: true,
  );
  Future<void> seedPin() async {
    final staged = await store.stageReplacement(
      _authority,
      PinRecord(leafDerSha256: _digest, createdAt: DateTime.utc(2026)),
    );
    await (staged as PinStageSuccess).transaction.commit();
  }

  void dispose() => container.dispose();
}

NativeProbeCertificate _certificate() => NativeProbeCertificate(
  PresentedCertificate(
    namesAuthority: true,
    authority: _authority,
    platformTrust: PlatformTrust.didNotPass,
    facts: CertificateFacts(
      subjectSummary: 'CN: nas.example',
      issuerSummary: 'Synthetic test CA',
      leafDerSha256: _digest,
      notValidBefore: DateTime.utc(2026),
      notValidAfter: DateTime.utc(2027),
    ),
  ),
);

final class _Probe implements NativeCertificateProbe {
  int calls = 0;
  Completer<NativeProbeOutcome>? delayed;
  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    calls++;
    return delayed?.future ?? _certificate();
  }
}

final class _PinnedConnector implements PinnedRpcConnector {
  int calls = 0;
  final outcomes = <NativePinnedOutcome>[];
  Completer<NativePinnedOutcome>? delayed;
  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    calls++;
    return delayed?.future ??
        (outcomes.isEmpty
            ? NativePinnedVerified(_Transport())
            : outcomes.removeAt(0));
  }
}

final class _Transport implements RpcTransport {
  int closeCalls = 0;
  @override
  Stream<String> get inboundFrames => const Stream.empty();
  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<void> send(String frame) async =>
      throw StateError('No real RPC in fixture.');
}

final class _PasswordRepository
    implements SessionRepository, PasswordSessionRepository {
  _PasswordRepository({this.connector});
  final RpcConnector? connector;
  final passwords = <String>[];
  final tokens = <String?>[];
  final endpoints = <Uri>[];
  int keyCalls = 0, closeCalls = 0;
  RpcTransport? consumed;
  @override
  Future<ServerSummary> connectWithPassword({
    required String serverInput,
    required String password,
    required String username,
    PasswordOtpResponder? onOtpRequired,
    bool Function()? isConnectionCurrent,
  }) async {
    final endpoint = Uri.parse(serverInput);
    consumed = await connector!.connect(endpoint);
    endpoints.add(endpoint);
    passwords.add(password);
    final token = await onOtpRequired!(
      PasswordOtpChallenge(
        endpoint: endpoint.toString(),
        username: username,
        attempt: 1,
        expiresAt: DateTime.utc(2030),
      ),
    );
    tokens.add(token);
    // Deliberately return even after cancellation: the controller must fence
    // late completions independently of a cooperative SDK implementation.
    return ServerSummary(
      originalHostInput: serverInput,
      endpointUri: endpoint,
      identity: username,
      version: '25.10.1',
      availableMethodNames: const {},
    );
  }

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async {
    keyCalls++;
    throw StateError('API keys must not reach this fixture.');
  }

  @override
  Future<void> close() async {
    closeCalls++;
    final transport = consumed;
    consumed = null;
    await transport?.close();
  }
}
