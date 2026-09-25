import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/connection/connection_state.dart';
import 'package:trueraid/features/server_profiles/server_profiles_controller.dart';
import 'package:trueraid/features/tls_trust/tls_trust_providers.dart';
import 'package:trueraid/trueraid_app.dart';
import 'package:truenas_api/truenas_api.dart';

const _password = ' synthetic password only ';
final _challenge = PasswordOtpChallenge(
  endpoint: 'wss://nas.example/api/current',
  username: 'alice',
  attempt: 1,
  expiresAt: DateTime.utc(2030),
);

void main() {
  test('password mode uses additive interface and publishes only safe profile after OTP', () async {
    final repo = _PasswordRepo();
    final container = _container(repo);
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    final pending = _connect(controller);
    await _turns();
    expect(repo.passwords, [_password]);
    expect(repo.keyCalls, 0);
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionOtpRequired>(),
    );
    expect(controller.activeSession, isNull);
    expect(
      container.read(serverProfilesControllerProvider).selectedProfile,
      isNull,
    );
    expect(controller.submitOtp(_challenge, '123456'), isTrue);
    expect(controller.submitOtp(_challenge, '123456'), isFalse);
    await pending;
    expect(repo.tokens, ['123456']);
    expect(controller.activeSession, isNotNull);
    final profile = container
        .read(serverProfilesControllerProvider)
        .selectedProfile!;
    expect(profile.normalizedEndpoint, 'wss://nas.example/api/current');
    expect(profile.toString(), isNot(contains(_password)));
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionSucceeded>(),
    );
  });
  for (final token in [
    '',
    '12345',
    '123456789',
    'abcdef',
    ' 123456',
    '123456\n',
  ]) {
    test(
      'invalid OTP ${token.length} never completes pending challenge',
      () async {
        final repo = _PasswordRepo();
        final container = _container(repo);
        addTearDown(container.dispose);
        final controller = container.read(
          connectionControllerProvider.notifier,
        );
        final pending = _connect(controller);
        await _turns();
        expect(controller.submitOtp(_challenge, token), isFalse);
        expect(repo.tokens, isEmpty);
        controller.cancelPasswordSignIn();
        await pending;
        expect(controller.activeSession, isNull);
        expect(repo.tokens, [null]);
      },
    );
  }
  test('forged challenge and late code after cancel are rejected', () async {
    final repo = _PasswordRepo();
    final container = _container(repo);
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    final pending = _connect(controller);
    await _turns();
    final forged = PasswordOtpChallenge(
      endpoint: _challenge.endpoint,
      username: _challenge.username,
      attempt: 1,
      expiresAt: _challenge.expiresAt,
    );
    expect(controller.submitOtp(forged, '123456'), isFalse);
    controller.cancelPasswordSignIn();
    await pending;
    expect(controller.submitOtp(_challenge, '123456'), isFalse);
    expect(repo.closeCalls, greaterThan(0));
    expect(controller.activeSession, isNull);
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionFailed>(),
    );
  });
  test('an old cancelled attempt cannot cancel a newer OTP prompt', () async {
    final old = _PasswordRepo()..afterOtp = Completer<void>();
    final fresh = _PasswordRepo();
    var creation = 0;
    final container = ProviderContainer(
      overrides: [
        tlsTrustRouteProvider.overrideWithValue(
          TlsTrustRoute.platformValidated,
        ),
        sessionRepositoryProvider.overrideWith(
          (ref) => creation++ == 0 ? old : fresh,
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(connectionControllerProvider.notifier);
    final first = _connect(controller);
    await _turns();
    controller.cancelPasswordSignIn();
    final second = _connect(controller);
    await _turns();
    expect(fresh.passwords, [_password]);
    old.afterOtp!.complete();
    await first;
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionOtpRequired>(),
    );
    expect(controller.submitOtp(_challenge, '654321'), isTrue);
    await second;
    expect(fresh.tokens, ['654321']);
    expect(controller.activeSession?.repository, same(fresh));
  });
  test(
    'controller disposal completes OTP with null and closes its attempt',
    () async {
      final repo = _PasswordRepo();
      final container = _container(repo);
      final pending = _connect(
        container.read(connectionControllerProvider.notifier),
      );
      await _turns();
      container.dispose();
      await pending;
      expect(repo.tokens, [null]);
      expect(repo.closeCalls, greaterThan(0));
    },
  );
  test('invalid password is refused before repository handoff', () async {
    final repo = _PasswordRepo();
    final container = _container(repo);
    addTearDown(container.dispose);
    await container
        .read(connectionControllerProvider.notifier)
        .connect(
          serverInput: 'https://nas.example',
          apiKey: null,
          username: 'alice',
          password: '',
        );
    expect(repo.passwords, isEmpty);
    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionFailed>(),
    );
  });
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'password and OTP at ${width.toInt()}px 200% with keyboard remain usable',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(
          tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
        );
        final repo = _PasswordRepo();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              tlsTrustRouteProvider.overrideWithValue(
                TlsTrustRoute.platformValidated,
              ),
              sessionRepositoryProvider.overrideWithValue(repo),
            ],
            child: const TrueRAIDApp(),
          ),
        );
        await tester.ensureVisible(
          find.byKey(const Key('login-method-password')),
        );
        await tester.tap(find.byKey(const Key('login-method-password')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('remember-api-key-control')), findsNothing);
        expect(find.byKey(const Key('api-key-field')), findsNothing);
        await tester.enterText(
          find.byKey(const Key('server-url-field')),
          'https://nas.example',
        );
        await tester.enterText(
          find.byKey(const Key('username-field')),
          'alice',
        );
        await tester.enterText(
          find.byKey(const Key('password-field')),
          _password,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('password-field')))
              .obscureText,
          isTrue,
        );
        await tester.ensureVisible(find.byKey(const Key('connect-button')));
        await tester.tap(find.byKey(const Key('connect-button')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('password-field')))
              .controller!
              .text,
          isEmpty,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('otp-field')));
        await tester.enterText(find.byKey(const Key('otp-field')), '12');
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('otp-field')))
              .obscureText,
          isTrue,
        );
        await tester.ensureVisible(find.byKey(const Key('otp-submit')));
        await tester.tap(find.byKey(const Key('otp-submit')));
        await tester.pumpAndSettle();
        expect(repo.tokens, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('otp-cancel')));
        await tester.tap(find.byKey(const Key('otp-cancel')));
        await tester.pumpAndSettle();
        expect(repo.tokens, [null]);
        expect(find.byKey(const Key('otp-panel')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

ProviderContainer _container(_PasswordRepo repository) => ProviderContainer(
  overrides: [
    tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.platformValidated),
    sessionRepositoryProvider.overrideWithValue(repository),
  ],
);
Future<void> _connect(ConnectionController controller) => controller.connect(
  serverInput: 'https://nas.example',
  apiKey: 'must-not-forward',
  username: 'alice',
  password: _password,
  rememberApiKey: true,
);
Future<void> _turns() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _PasswordRepo
    implements SessionRepository, PasswordSessionRepository {
  final passwords = <String>[];
  final tokens = <String?>[];
  int keyCalls = 0, closeCalls = 0;
  Completer<void>? afterOtp;
  @override
  Future<void> close() async {
    closeCalls++;
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
    throw StateError('Password must use its own capability.');
  }

  @override
  Future<ServerSummary> connectWithPassword({
    required String serverInput,
    required String password,
    required String username,
    PasswordOtpResponder? onOtpRequired,
    bool Function()? isConnectionCurrent,
  }) async {
    passwords.add(password);
    final token = await onOtpRequired!(_challenge);
    tokens.add(token);
    await afterOtp?.future;
    if (token == null || isConnectionCurrent?.call() == false) {
      throw const PasswordLoginException(PasswordLoginFailure.cancelled);
    }
    return ServerSummary(
      originalHostInput: serverInput,
      endpointUri: Uri.parse(_challenge.endpoint),
      identity: username,
      version: '25.10.1',
      availableMethodNames: const {},
    );
  }
}
