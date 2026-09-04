import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash/features/connection/connection_controller.dart';
import 'package:truedash/truedash_app.dart';
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
      expect(
        find.text('Unofficial · planning-era M0 connection check'),
        findsOneWidget,
      );
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
      expect(
        find.textContaining('wss://nas.example/api/current'),
        findsOneWidget,
      );
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
          .widget<FilledButton>(find.byKey(const Key('connect-button')))
          .onPressed,
      isNull,
    );
    repository.complete();
    await tester.pumpAndSettle();
  });
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
