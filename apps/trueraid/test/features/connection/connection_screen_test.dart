import 'dart:async';
import 'dart:ui' show CheckedState, Tristate;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/connection/connection_state.dart';
import 'package:trueraid/features/server_profiles/server_profiles_controller.dart';
import 'package:trueraid/features/tls_trust/certificate_facts.dart';
import 'package:trueraid/features/tls_trust/certificate_trust_coordinator.dart';
import 'package:trueraid/features/tls_trust/models.dart';
import 'package:trueraid/features/tls_trust/native_tls_ports.dart';
import 'package:trueraid/features/tls_trust/pin_store.dart';
import 'package:trueraid/features/tls_trust/tls_trust_providers.dart';
import 'package:trueraid/trueraid_app.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const sentinel = 'test-api-key';
const _newFingerprint =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _oldFingerprint =
    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

void main() {
  testWidgets(
    'successful connection enters the shell with safe profile metadata only',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _platformValidatedRoute,
            sessionRepositoryProvider.overrideWithValue(_SuccessRepository()),
          ],
          child: const TrueRAIDApp(),
        ),
      );
      expect(find.text('TrueRAID'), findsOneWidget);
      expect(find.text('Unofficial TrueNAS client'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://nas.example',
      );
      await tester.enterText(
        find.byKey(const Key('username-field')),
        'test-account',
      );
      await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('api-key-field')))
            .obscureText,
        isTrue,
      );
      expect(_visibleTextContains(sentinel), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsWidgets);
      expect(find.text('nas.example'), findsWidgets);
      expect(find.text('Connection summary'), findsNothing);
      expect(find.text('admin'), findsNothing);
      expect(find.text('25.10'), findsNothing);
      expect(find.text('2'), findsNothing);
      expect(_visibleTextContains(sentinel), findsNothing);
    },
  );

  testWidgets('safe failure does not render the API key sentinel', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _platformValidatedRoute,
          sessionRepositoryProvider.overrideWithValue(_FailureRepository()),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'wss://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(find.text('The server rejected the API key.'), findsOneWidget);
    expect(_visibleTextContains(sentinel), findsNothing);
  });

  testWidgets('only a successful connection creates a selected profile', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        _platformValidatedRoute,
        sessionRepositoryProvider.overrideWithValue(_SuccessRepository()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TrueRAIDApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();

    final profile = container
        .read(serverProfilesControllerProvider)
        .selectedProfile;
    expect(profile?.displayName, 'nas.example');
    expect(profile?.normalizedEndpoint, 'wss://nas.example/api/current');
  });

  testWidgets('shows progress and disables submission while connecting', (
    tester,
  ) async {
    final repository = _PendingRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _platformValidatedRoute,
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'wss://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pump();
    expect(find.text('Connecting securely…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<TdButton>(find.byKey(const Key('connect-button')))
          .onPressed,
      isNull,
    );
    repository.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('native remember control is unchecked, accessible, and opt-in', (
    tester,
  ) async {
    final repository = _RecordingRepository();
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _platformValidatedRoute,
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
        child: const TrueRAIDApp(),
      ),
    );

    final remember = find.byKey(const Key('remember-api-key-control'));
    expect(remember, findsOneWidget);
    expect(find.text('Remember API key on this device'), findsOneWidget);
    expect(find.textContaining('protected credential store'), findsOneWidget);
    expect(
      tester.getSemantics(remember).flagsCollection.isChecked,
      CheckedState.isFalse,
    );

    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(repository.rememberIntents, [false]);

    await tester.tap(remember);
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(repository.rememberIntents, [false, true]);
    expect(_visibleTextContains(sentinel), findsNothing);
    handle.dispose();
  });

  testWidgets('native empty API key keeps the empty credential intent', (
    tester,
  ) async {
    final repository = _RecordingRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _platformValidatedRoute,
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();

    expect(repository.apiKeys, [isEmpty]);
    expect(repository.rememberIntents, [false]);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('api-key-field')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('browser-managed route has no interactive remember control', (
    tester,
  ) async {
    final repository = _RecordingRepository();
    final vault = _TrackingVault();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.browserManaged),
          sessionRepositoryProvider.overrideWithValue(repository),
          credentialVaultProvider.overrideWithValue(vault),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    expect(find.byKey(const Key('remember-api-key-control')), findsNothing);
    expect(
      find.textContaining('browser does not persist API keys'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(repository.apiKeys, isEmpty);
    expect(vault.writes, isEmpty);
  });

  testWidgets('busy native form disables the remember control', (tester) async {
    final repository = _PendingRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _platformValidatedRoute,
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await tester.ensureVisible(
      find.byKey(const Key('remember-api-key-control')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remember-api-key-control')));
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pump();
    expect(
      tester
          .getSemantics(find.byKey(const Key('remember-api-key-control')))
          .flagsCollection
          .isEnabled,
      Tristate.isFalse,
    );
    repository.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a blank user name is refused before any connection', (
    tester,
  ) async {
    final repository = _RecordingRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _platformValidatedRoute,
          sessionRepositoryProvider.overrideWithValue(repository),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://nas.example',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('A TrueNAS user name is required with an API key.'),
      findsOneWidget,
    );
    expect(repository.apiKeys, isEmpty);
  });

  testWidgets(
    'a certificate that does not name the server warns before approval',
    (tester) async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
            certificateTrustCoordinatorProvider.overrideWithValue(
              _trustCoordinator(authority: authority, namesAuthority: false),
            ),
          ],
          child: const TrueRAIDApp(),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://nas.example',
      );
      await tester.enterText(
        find.byKey(const Key('username-field')),
        'test-account',
      );
      await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('hostname-mismatch-warning')),
        findsOneWidget,
      );
      expect(
        find.text('This certificate does not name this server address.'),
        findsOneWidget,
      );
      // The mismatch is a warning, not a block: approval stays reachable and
      // the fingerprint is still the identity the user is asked to confirm.
      expect(find.byKey(const Key('approve-trust-button')), findsOneWidget);
      expect(find.byKey(const Key('current-fingerprint')), findsOneWidget);
    },
  );

  testWidgets('a matching certificate shows no mismatch warning', (
    tester,
  ) async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          certificateTrustCoordinatorProvider.overrideWithValue(
            _trustCoordinator(authority: authority),
          ),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('hostname-mismatch-warning')), findsNothing);
    expect(find.byKey(const Key('approve-trust-button')), findsOneWidget);
  });

  testWidgets(
    'first trust review shows complete facts before approval and forwards checked intent',
    (tester) async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final repository = _RecordingRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
            certificateTrustCoordinatorProvider.overrideWithValue(
              _trustCoordinator(authority: authority),
            ),
            sessionRepositoryFactoryProvider.overrideWithValue(
              ({required connector, required credentialVault}) => repository,
            ),
          ],
          child: const TrueRAIDApp(),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://nas.example',
      );
      await tester.enterText(
        find.byKey(const Key('username-field')),
        'test-account',
      );
      await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
      await tester.ensureVisible(
        find.byKey(const Key('remember-api-key-control')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remember-api-key-control')));
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();

      expect(find.text('Server'), findsOneWidget);
      expect(find.text('https://nas.example:443'), findsOneWidget);
      expect(find.text('Subject'), findsOneWidget);
      expect(find.text('CN: nas.example'), findsOneWidget);
      expect(find.text('Issuer'), findsOneWidget);
      expect(find.text('Example Test CA'), findsOneWidget);
      expect(find.text('Valid from'), findsOneWidget);
      expect(find.text('2026-01-02 03:04:05 UTC'), findsOneWidget);
      expect(find.text('Valid to'), findsOneWidget);
      expect(find.text('2027-02-03 04:05:06 UTC'), findsOneWidget);
      expect(find.text('Platform trust'), findsOneWidget);
      expect(find.text('Did not pass'), findsOneWidget);
      expect(find.text('SHA-256 fingerprint'), findsOneWidget);
      expect(find.byKey(const Key('current-fingerprint')), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('current-fingerprint')),
            )
            .maxLines,
        isNull,
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('current-fingerprint')),
            )
            .data,
        _newFingerprint,
      );
      expect(find.byKey(const Key('approve-trust-button')), findsOneWidget);
      expect(
        find.byKey(const Key('cancel-trust-review-button')),
        findsOneWidget,
      );
      expect(_visibleTextContains(sentinel), findsNothing);

      await _tapVisible(tester, const Key('approve-trust-button'));
      await tester.pumpAndSettle();
      expect(repository.apiKeys, [sentinel]);
      expect(repository.rememberIntents, [true]);
    },
  );

  testWidgets(
    'replacement review distinguishes previous and new pins and cancel keeps the old pin',
    (tester) async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final store = InMemoryPinStore();
      await _seedPin(store, authority, _oldFingerprint);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
            certificateTrustCoordinatorProvider.overrideWithValue(
              _trustCoordinator(
                authority: authority,
                store: store,
                connector: _TrustConnector([
                  const NativePinnedFailure(
                    CertificateTrustFailure.pinMismatch,
                  ),
                ]),
              ),
            ),
          ],
          child: const TrueRAIDApp(),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://nas.example',
      );
      await tester.enterText(
        find.byKey(const Key('username-field')),
        'test-account',
      );
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();

      expect(find.text('Previous fingerprint'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('previous-fingerprint')),
            )
            .data,
        _oldFingerprint,
      );
      expect(find.text('New fingerprint'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('new-fingerprint')))
            .data,
        _newFingerprint,
      );
      expect(find.byKey(const Key('approve-trust-button')), findsOneWidget);
      expect(
        (await store.read(authority) as PinRecordRead).record.leafDerSha256,
        _oldFingerprint,
      );

      await _tapVisible(tester, const Key('cancel-trust-review-button'));
      await tester.pumpAndSettle();
      expect(
        (await store.read(authority) as PinRecordRead).record.leafDerSha256,
        _oldFingerprint,
      );
    },
  );

  testWidgets(
    'blocked retry forwards checked intent without rendering the key',
    (tester) async {
      final authority = NormalizedAuthority.parse('https://nas.example');
      final repository = _RecordingRepository();
      final store = InMemoryPinStore();
      await _seedPin(store, authority, _newFingerprint);
      final container = ProviderContainer(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          certificateTrustCoordinatorProvider.overrideWithValue(
            _trustCoordinator(
              authority: authority,
              store: store,
              connector: _TrustConnector([
                const NativePinnedFailure(
                  CertificateTrustFailure.pinnedReconnectFailed,
                ),
                NativePinnedVerified(_TrustTransport()),
              ]),
            ),
          ),
          sessionRepositoryFactoryProvider.overrideWithValue(
            ({required connector, required credentialVault}) => repository,
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TrueRAIDApp(),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://nas.example',
      );
      await tester.enterText(
        find.byKey(const Key('username-field')),
        'test-account',
      );
      await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
      await tester.ensureVisible(
        find.byKey(const Key('remember-api-key-control')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remember-api-key-control')));
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('retry-trust-button')), findsOneWidget);
      expect(
        find.text('The pinned certificate could not be verified.'),
        findsOneWidget,
      );
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionTrustBlocked>(),
      );
      expect(
        container.read(connectionControllerProvider).toString(),
        isNot(contains(sentinel)),
      );
      expect(_visibleTextContains(sentinel), findsNothing);
      await _tapVisible(tester, const Key('retry-trust-button'));
      await tester.pumpAndSettle();
      expect(repository.apiKeys, [sentinel]);
      expect(repository.rememberIntents, [true]);
    },
  );

  testWidgets('invalid review fingerprints fail closed without approval', (
    tester,
  ) async {
    final authority = NormalizedAuthority.parse('https://nas.example');
    final coordinator = _trustCoordinator(authority: authority);
    final nativeReview = await coordinator.begin(authority) as FirstTrustReview;
    final invalidReview = ConnectionFirstTrustReview(
      token: nativeReview.token,
      authority: authority,
      certificate: TrustReviewCertificate(
        namesAuthority: true,
        subjectSummary: 'CN: nas.example',
        issuerSummary: 'Example Test CA',
        leafDerSha256: 'NOT-HEX',
        notValidBefore: DateTime.utc(2026),
        notValidAfter: DateTime.utc(2027),
        platformTrust: PlatformTrust.didNotPass,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          connectionControllerProvider.overrideWith(
            () => _FixedConnectionController(invalidReview),
          ),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    expect(find.byKey(const Key('approve-trust-button')), findsNothing);
    expect(
      find.text('Certificate review details are unavailable.'),
      findsOneWidget,
    );
  });

  testWidgets('trust review scrolls without overflow at 320px and 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
    final authority = NormalizedAuthority.parse('https://nas.example');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.native),
          certificateTrustCoordinatorProvider.overrideWithValue(
            _trustCoordinator(authority: authority),
          ),
        ],
        child: const TrueRAIDApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://nas.example',
    );
    await tester.enterText(
      find.byKey(const Key('username-field')),
      'test-account',
    );
    await _tapVisible(tester, const Key('connect-button'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('approve-trust-button')),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.byKey(const Key('approve-trust-button')), findsOneWidget);
    expect(find.byKey(const Key('current-fingerprint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'remember control at ${width.toInt()}px and 200% text scale has no overflow',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(
          tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              _platformValidatedRoute,
              sessionRepositoryProvider.overrideWithValue(
                _RecordingRepository(),
              ),
            ],
            child: const TrueRAIDApp(),
          ),
        );
        await tester.enterText(
          find.byKey(const Key('server-url-field')),
          'https://nas.example',
        );
        await tester.enterText(
          find.byKey(const Key('username-field')),
          'test-account',
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('remember-api-key-control')),
          300,
          scrollable: find.byType(Scrollable).first,
        );

        expect(tester.takeException(), isNull);
        final remember = find.byKey(const Key('remember-api-key-control'));
        expect(remember, findsOneWidget);
        expect(tester.getSize(remember).height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(remember).flagsCollection.isEnabled,
          Tristate.isTrue,
        );
      },
    );
  }

  for (final failure in <_FailureCase>[
    _FailureCase(
      const EndpointValidationException(
        'Enter a secure server URL with a host.',
      ),
      'Enter a secure server URL with a host.',
    ),
    _FailureCase(
      const TlsCertificateException(),
      'A trusted TLS certificate is required in this M0 slice. Certificate trust settings are not available yet.',
    ),
    _FailureCase(
      const JsonRpcRemoteException(code: -32000, message: 'private'),
      'The server returned an RPC error. Check access and try again.',
    ),
    _FailureCase(
      const RpcTransportClosedException(),
      'The secure connection closed before setup finished.',
    ),
    _FailureCase(
      const JsonRpcProtocolException('private'),
      'The server sent an invalid RPC response.',
    ),
    _FailureCase(
      const AuthenticationStateException(AuthenticationState.otpRequired),
      'This server requires an OTP flow, which M0 does not support yet.',
    ),
    _FailureCase(
      const AuthenticationStateException(AuthenticationState.expired),
      'The API key has expired.',
    ),
    _FailureCase(
      const AuthenticationStateException(AuthenticationState.redirect),
      'This server requested a redirect, which M0 does not support yet.',
    ),
    _FailureCase(
      StateError('private'),
      'Unable to reach the server over a secure connection.',
    ),
  ]) {
    testWidgets('maps ${failure.label} to a safe message', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _platformValidatedRoute,
            sessionRepositoryProvider.overrideWithValue(
              _ThrowingRepository(failure.error),
            ),
          ],
          child: const TrueRAIDApp(),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'wss://nas.example',
      );
      await tester.enterText(
        find.byKey(const Key('username-field')),
        'test-account',
      );
      await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();

      expect(find.text(failure.expectedMessage), findsOneWidget);
      expect(_visibleTextContains(sentinel), findsNothing);
    });
  }

  test('repository provider composes independently overrideable seams', () {
    final connector = _UnusedConnector();
    final vault = _TrackingVault();
    late RpcConnector usedConnector;
    late CredentialVault usedVault;
    final container = ProviderContainer(
      overrides: [
        rpcConnectorProvider.overrideWithValue(connector),
        credentialVaultProvider.overrideWithValue(vault),
        sessionRepositoryFactoryProvider.overrideWithValue(({
          required connector,
          required credentialVault,
        }) {
          usedConnector = connector;
          usedVault = credentialVault;
          return _SuccessRepository();
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(sessionRepositoryProvider),
      isA<_SuccessRepository>(),
    );
    expect(usedConnector, same(connector));
    expect(usedVault, same(vault));
  });
}

final _platformValidatedRoute = tlsTrustRouteProvider.overrideWithValue(
  TlsTrustRoute.platformValidated,
);

final class _FailureCase {
  const _FailureCase(this.error, this.expectedMessage);
  final Object error;
  final String expectedMessage;
  String get label => error.runtimeType.toString();
}

Finder _visibleTextContains(String value) => find.byWidgetPredicate(
  (widget) => widget is Text && (widget.data?.contains(value) ?? false),
);

final class _SuccessRepository implements SessionRepository {
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async => ServerSummary(
    originalHostInput: serverInput,
    endpointUri: Uri.parse('wss://nas.example/api/current'),
    identity: 'admin',
    version: '25.10',
    availableMethodNames: const {'a', 'b'},
  );
}

final class _FailureRepository implements SessionRepository {
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async => throw const AuthenticationStateException(
    AuthenticationState.authenticationFailed,
  );
}

final class _PendingRepository implements SessionRepository {
  final _completion = Completer<ServerSummary>();
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => _completion.future;
  void complete() => _completion.complete(
    ServerSummary(
      originalHostInput: 'wss://nas.example',
      endpointUri: Uri.parse('wss://nas.example/api/current'),
      identity: 'admin',
      version: '25.10',
      availableMethodNames: const {},
    ),
  );
}

final class _RecordingRepository implements SessionRepository {
  final rememberIntents = <bool>[];
  final apiKeys = <String?>[];

  @override
  Future<void> close() async {}

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async {
    rememberIntents.add(rememberApiKey);
    apiKeys.add(apiKey);
    throw StateError('contained test failure');
  }
}

final class _ThrowingRepository implements SessionRepository {
  const _ThrowingRepository(this.error);
  final Object error;
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => Future<ServerSummary>.error(error);
}

final class _UnusedConnector implements RpcConnector {
  @override
  Future<RpcTransport> connect(Uri endpoint) => throw UnimplementedError();
}

final class _TrackingVault implements CredentialVault {
  final writes = <String>[];
  @override
  Future<void> deleteApiKey(String endpointIdentifier) async {}
  @override
  Future<String?> readApiKey(String endpointIdentifier) async => null;
  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async => writes.add(endpointIdentifier);
}

CertificateTrustCoordinator _trustCoordinator({
  required NormalizedAuthority authority,
  PinStore? store,
  PinnedRpcConnector? connector,
  bool namesAuthority = true,
}) => CertificateTrustCoordinator(
  pinStore: store ?? InMemoryPinStore(),
  probe: _TrustProbe(
    NativeProbeCertificate(
      PresentedCertificate(
        namesAuthority: namesAuthority,
        authority: authority,
        platformTrust: PlatformTrust.didNotPass,
        facts: CertificateFacts(
          subjectSummary: 'CN: nas.example',
          issuerSummary: 'Example Test CA',
          leafDerSha256: _newFingerprint,
          notValidBefore: DateTime.utc(2026, 1, 2, 3, 4, 5),
          notValidAfter: DateTime.utc(2027, 2, 3, 4, 5, 6),
        ),
      ),
    ),
  ),
  connector:
      connector ?? _TrustConnector([NativePinnedVerified(_TrustTransport())]),
  now: () => DateTime.utc(2026, 6),
  probeTimeout: const Duration(seconds: 1),
  reconnectTimeout: const Duration(seconds: 1),
);

Future<void> _seedPin(
  PinStore store,
  NormalizedAuthority authority,
  String fingerprint,
) async {
  final staged = await store.stageReplacement(
    authority,
    PinRecord(leafDerSha256: fingerprint, createdAt: DateTime.utc(2025)),
  );
  expect(staged, isA<PinStageSuccess>());
  await (staged as PinStageSuccess).transaction.commit();
}

final class _TrustProbe implements NativeCertificateProbe {
  const _TrustProbe(this.outcome);
  final NativeProbeOutcome outcome;

  @override
  Future<NativeProbeOutcome> probe({
    required NormalizedAuthority authority,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async => outcome;
}

final class _TrustConnector implements PinnedRpcConnector {
  _TrustConnector(this.outcomes);
  final List<NativePinnedOutcome> outcomes;
  var _index = 0;

  @override
  Future<NativePinnedOutcome> reconnect({
    required NormalizedAuthority authority,
    required PinRecord pin,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async => outcomes[_index++];
}

final class _TrustTransport implements RpcTransport {
  @override
  Stream<String> get inboundFrames => const Stream.empty();

  @override
  Future<void> close() async {}

  @override
  Future<void> send(String frame) async {}
}

final class _FixedConnectionController extends ConnectionController {
  _FixedConnectionController(this.fixedState);
  final ConnectionState fixedState;

  @override
  ConnectionState build() => fixedState;
}

Future<void> _tapVisible(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
