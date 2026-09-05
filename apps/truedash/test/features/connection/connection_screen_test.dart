import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash/features/connection/connection_controller.dart';
import 'package:truedash/truedash_app.dart';
import 'package:truedash_design_system/truedash_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const sentinel = 'test-api-key';

void main() {
  testWidgets(
    'scope-free app masks credentials and shows a safe success summary',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionRepositoryProvider.overrideWithValue(_SuccessRepository()),
          ],
          child: const TrueDashApp(),
        ),
      );
      expect(find.text('TrueDash'), findsOneWidget);
      expect(find.text('Unofficial TrueNAS client'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'https://nas.example',
      );
      await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('api-key-field')))
            .obscureText,
        isTrue,
      );
      expect(_visibleTextContains(sentinel), findsNothing);
      await tester.tap(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Original host'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('connection-summary')),
          matching: find.text('https://nas.example'),
        ),
        findsOneWidget,
      );
      expect(find.text('wss://nas.example/api/current'), findsOneWidget);
      expect(find.text('admin'), findsOneWidget);
      expect(find.text('25.10'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(_visibleTextContains(sentinel), findsNothing);
    },
  );

  testWidgets('safe failure does not render the API key sentinel', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionRepositoryProvider.overrideWithValue(_FailureRepository()),
        ],
        child: const TrueDashApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'wss://nas.example',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(find.text('The server rejected the API key.'), findsOneWidget);
    expect(_visibleTextContains(sentinel), findsNothing);
  });

  testWidgets('shows progress and disables submission while connecting', (
    tester,
  ) async {
    final repository = _PendingRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionRepositoryProvider.overrideWithValue(repository)],
        child: const TrueDashApp(),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'wss://nas.example',
    );
    await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
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

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'success summary at ${width.toInt()}px and 200% text scale reflows without overflow',
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
              sessionRepositoryProvider.overrideWithValue(
                _LongSuccessRepository(),
              ),
            ],
            child: const TrueDashApp(),
          ),
        );
        await tester.enterText(
          find.byKey(const Key('server-url-field')),
          'https://nas.example',
        );
        await tester.enterText(
          find.byKey(const Key('api-key-field')),
          sentinel,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('connect-button')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(const Key('connect-button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Connection summary'), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        final title = tester.getTopLeft(find.text('Connection summary'));
        final action = tester.getTopLeft(find.text('Connected'));
        expect(action.dy, greaterThan(title.dy));
        final endpoint = tester.renderObject<RenderParagraph>(
          find.text(
            'wss://nas.example/api/current/with/a/long/inspectable/path',
          ),
        );
        expect(endpoint.size.height, greaterThan(40));
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
            sessionRepositoryProvider.overrideWithValue(
              _ThrowingRepository(failure.error),
            ),
          ],
          child: const TrueDashApp(),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('server-url-field')),
        'wss://nas.example',
      );
      await tester.enterText(find.byKey(const Key('api-key-field')), sentinel);
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
    required String apiKey,
  }) async => ServerSummary(
    originalHostInput: serverInput,
    endpointUri: Uri.parse('wss://nas.example/api/current'),
    identity: 'admin',
    version: '25.10',
    availableMethodNames: const {'a', 'b'},
  );
}

final class _LongSuccessRepository implements SessionRepository {
  @override
  Future<void> close() async {}

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String apiKey,
  }) async => ServerSummary(
    originalHostInput: serverInput,
    endpointUri: Uri.parse(
      'wss://nas.example/api/current/with/a/long/inspectable/path',
    ),
    identity: 'administrator with a long readable identity',
    version: '25.10.0-with-an-inspectable-build-metadata-value',
    availableMethodNames: const {'a', 'b'},
  );
}

final class _FailureRepository implements SessionRepository {
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String apiKey,
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
    required String apiKey,
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

final class _ThrowingRepository implements SessionRepository {
  const _ThrowingRepository(this.error);
  final Object error;
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String apiKey,
  }) => Future<ServerSummary>.error(error);
}

final class _UnusedConnector implements RpcConnector {
  @override
  Future<RpcTransport> connect(Uri endpoint) => throw UnimplementedError();
}

final class _TrackingVault implements CredentialVault {
  @override
  Future<void> deleteApiKey(String serverDisplayInput) async {}
  @override
  Future<String?> readApiKey(String serverDisplayInput) async => null;
  @override
  Future<void> writeApiKey(String serverDisplayInput, String apiKey) async {}
}
