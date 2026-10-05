import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/sample/cloud_credentials_preview.dart';
import 'package:truenavo/features/cloud_credentials/cloud_credentials_controller.dart';
import 'package:truenavo/features/cloud_credentials/cloud_credentials_editor.dart';
import 'package:truenavo/features/cloud_credentials/cloud_credentials_page.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _secret = 'synthetic-never-display';
CloudCredentialWriteOnlyInput _input() => CloudCredentialWriteOnlyInput.s3(
  accessKeyId: _secret,
  secretAccessKey: _secret,
  endpoint: '',
  region: '',
  skipRegion: false,
  signaturesV2: false,
  maxUploadParts: 10000,
);

class _Fake with CloudCredentialsPreviewAdapter implements SessionRepository {
  int reads = 0;
  final reviews = <CloudCredentialRequest>[],
      writes = <CloudCredentialReview>[];
  CloudCredentialWriteOnlyInput? receivedInput;
  Future<CloudCredentialInventory> Function()? onLoad;
  Future<CloudCredentialReview> Function(CloudCredentialRequest)? onReview;
  Future<CloudCredentialResult> Function()? onExecute;
  @override
  Future<CloudCredentialInventory> loadCloudCredentials() async {
    reads++;
    return onLoad?.call() ?? CloudCredentialsPreviewAdapter.inventory;
  }

  @override
  Future<CloudCredentialReview> reviewCloudCredential(
    CloudCredentialRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ?? super.reviewCloudCredential(request);
  }

  @override
  Future<CloudCredentialResult> executeCloudCredential(
    CloudCredentialReview review,
    String confirmation, {
    CloudCredentialWriteOnlyInput? input,
  }) async {
    writes.add(review);
    receivedInput = input;
    return onExecute?.call() ??
        const CloudCredentialResult(
          CloudCredentialOutcome.succeeded,
          'Saved configuration only',
        );
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('No transport');
}

class _Harness {
  _Harness() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final api = _Fake();
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String endpoint = 'wss://nas-demo.example/api/current',
  }) => AuthenticatedSession(
    profileId: 'sample',
    repository: api,
    availableMethodNames: const {},
    version: '25.10.1',
    endpoint: endpoint,
  );
  void select(AuthenticatedSession? value) {
    active = value;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  CloudCredentialReview review() => CloudCredentialReview(
    request: CloudCredentialRequest(
      inventory: CloudCredentialsPreviewAdapter.inventory,
      action: CloudCredentialAction.replace,
      credential: CloudCredentialsPreviewAdapter.inventory.credentials.last,
    ),
    endpoint: session.endpoint!,
    warnings: const ['Replace every provider field.'],
  );
  CloudCredentialsController get controller =>
      container.read(cloudCredentialsControllerProvider.notifier);
  Future<void> execute({
    CloudCredentialReview? review,
    CloudCredentialWriteOnlyInput? input,
    String? confirmation,
  }) {
    final r = review ?? this.review();
    return controller.execute(
      expectedSession: session,
      review: r,
      confirmation: confirmation ?? r.target,
      input: input,
    );
  }

  void dispose() => container.dispose();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  double width = 800,
  double scale = 1,
  double keyboard = 0,
  bool disconnected = false,
  bool light = false,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = _Harness();
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    await h.container.read(cloudCredentialsInventoryProvider.future);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: light ? TrueNavoTheme.light() : TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const CloudCredentialsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> _createEditor(WidgetTester tester) async {
  await _tap(tester, 'cloud-credential-create');
  await _enter(tester, 'cloud-credential-name', 'New');
  await _enter(tester, 'cloud-credential-access-key', _secret);
  await _enter(tester, 'cloud-credential-secret-key', _secret);
  await _tap(tester, 'cloud-credential-complete');
}

void main() {
  for (final phase in ['editor', 'review']) {
    testWidgets('background permanently expires $phase and discards inputs', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final h = await _pump(tester);
      await _createEditor(tester);
      final secret = tester
          .widget<TextField>(
            find.byKey(const Key('cloud-credential-secret-key')),
          )
          .controller!;
      if (phase == 'review') {
        await _tap(tester, 'cloud-credential-editor-review');
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(secret.text, isEmpty);
      expect(
        find.text(phase == 'editor' ? 'Editor expired' : 'Review expired'),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.text(phase == 'editor' ? 'Editor expired' : 'Review expired'),
        findsOneWidget,
      );
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('already inactive app cannot open secret editor', (tester) async {
    final h = await _pump(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await _tap(tester, 'cloud-credential-create');
    expect(find.byType(CloudCredentialsEditor), findsNothing);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  test('inventory failure is not retried and never mutates', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onLoad = () => Future.error(StateError(_secret));
    await expectLater(
      h.container.read(cloudCredentialsInventoryProvider.future),
      throwsStateError,
    );
    await h.container.pump();
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
  });
  test(
    'ephemeral inputs never enter state and are discarded on success',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final input = _input();
      await h.execute(input: input);
      expect(h.api.writes.length, 1);
      expect(input.disposed, true);
      expect(
        h.container.read(cloudCredentialsControllerProvider).result?.message,
        'Saved configuration only',
      );
      expect(
        h.container.read(cloudCredentialsControllerProvider).toString(),
        isNot(contains(_secret)),
      );
    },
  );
  test('one-shot review and shared lock prevent duplicates', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final held = Completer<CloudCredentialResult>();
    h.api.onExecute = () => held.future;
    final r = h.review(),
        input = _input(),
        first = h.execute(review: r, input: input),
        secondInput = _input();
    await h.execute(review: r, input: secondInput);
    expect(secondInput.disposed, true);
    expect(h.api.writes.length, 1);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    held.complete(
      const CloudCredentialResult(CloudCredentialOutcome.succeeded, 'Saved'),
    );
    await first;
    await h.execute(review: r, input: _input());
    expect(input.disposed, true);
    expect(h.api.writes.length, 1);
  });
  test('other workspace lock rejects and discards credentials', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider),
        owner = lock.acquire()!,
        input = _input();
    await h.execute(input: input);
    expect(h.api.writes, isEmpty);
    expect(input.disposed, true);
    lock.release(owner);
  });
  for (final unknown in [false, true]) {
    test(
      '${unknown ? 'unknown reply' : 'thrown error'} retains lock without retry or secret exposure',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        h.api.onExecute = unknown
            ? () async => const CloudCredentialResult(
                CloudCredentialOutcome.unknown,
                'Unknown',
              )
            : () => Future.error(StateError(_secret));
        final input = _input();
        await h.execute(input: input);
        expect(input.disposed, true);
        expect(
          h.container.read(cloudCredentialsControllerProvider).locked,
          true,
        );
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
        expect(
          h.container.read(cloudCredentialsControllerProvider).result?.message,
          isNot(contains(_secret)),
        );
        await h.execute(input: _input());
        expect(h.api.writes.length, 1);
      },
    );
  }
  test('changed session drops late completion and requires original-server reconnect', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final held = Completer<CloudCredentialResult>();
    h.api.onExecute = () => held.future;
    final input = _input(), operation = h.execute(input: input);
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    held.complete(
      const CloudCredentialResult(CloudCredentialOutcome.succeeded, 'Late'),
    );
    await operation;
    expect(input.disposed, true);
    expect(h.container.read(cloudCredentialsControllerProvider).unknown, true);
    expect(h.controller.canAcknowledge, false);
    h.select(h.newSession());
    expect(h.controller.canAcknowledge, true);
    h.controller.acknowledgeAfterReconnect();
    expect(h.container.read(cloudCredentialsControllerProvider).locked, false);
    expect(h.api.writes.length, 1);
  });
  for (final mismatch in ['target', 'endpoint', 'session']) {
    test('$mismatch mismatch never sends and disposes input', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final input = _input();
      var r = h.review();
      if (mismatch == 'endpoint') {
        r = CloudCredentialReview(
          request: r.request,
          endpoint: 'wss://other.example/api/current',
          warnings: const [],
        );
      }
      if (mismatch == 'session') h.select(h.newSession());
      await h.execute(
        review: r,
        input: input,
        confirmation: mismatch == 'target' ? '${r.target} ' : null,
      );
      expect(input.disposed, true);
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('page and refresh inspect references only', (tester) async {
    final h = await _pump(tester);
    expect(find.text('Credential coverage'), findsOneWidget);
    expect(find.text('Archive S3'), findsOneWidget);
    await _tap(tester, 'cloud-credentials-refresh');
    expect(h.api.reads, 2);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('disconnected page performs zero reads', (tester) async {
    final h = await _pump(tester, disconnected: true);
    expect(find.text('Cloud credentials unavailable'), findsOneWidget);
    expect(find.byKey(const Key('cloud-credential-create')), findsNothing);
    expect(h.api.reads, 0);
  });
  testWidgets(
    'counts explicitly describe references not authentication health',
    (tester) async {
      await _pump(tester);
      expect(find.text('Reference counts, not cloud health'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == '2 of 4 credentials referenced by tasks',
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets('used delete and active schedule replacement disabled', (
    tester,
  ) async {
    await _pump(tester);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('cloud-credential-delete-1')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('cloud-credential-replace-1')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('cloud-credential-replace-2')),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('cloud-credential-delete-4')),
          )
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'unsupported provider retains safe inventory and disabled actions',
    (tester) async {
      await _pump(tester);
      expect(find.text('Legacy OneDrive'), findsOneWidget);
      for (final action in ['rename', 'replace', 'delete']) {
        expect(
          tester
              .widget<TextButton>(find.byKey(Key('cloud-credential-$action-3')))
              .onPressed,
          isNull,
        );
      }
    },
  );
  testWidgets('opening editor never exposes or autofills existing secrets', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'cloud-credential-replace-4');
    expect(find.byType(CloudCredentialsEditor), findsOneWidget);
    for (final key in ['access-key', 'secret-key', 'region']) {
      final field = tester.widget<TextField>(
        find.byKey(Key('cloud-credential-$key')),
      );
      expect(field.controller!.text, isEmpty);
      expect(field.obscureText, true);
      expect(field.autocorrect, false);
      expect(field.enableSuggestions, false);
      expect(field.enableIMEPersonalizedLearning, false);
    }
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('cancel editor clears secret controllers and sends nothing', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _createEditor(tester);
    final field = tester.widget<TextField>(
      find.byKey(const Key('cloud-credential-secret-key')),
    );
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(field.controller!.text, isEmpty);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'create needs complete-values acknowledgment and exact-target confirmation',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, 'cloud-credential-create');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('cloud-credential-editor-review')),
            )
            .onPressed,
        isNull,
      );
      await _enter(tester, 'cloud-credential-name', 'New');
      await _enter(tester, 'cloud-credential-access-key', _secret);
      await _enter(tester, 'cloud-credential-secret-key', _secret);
      await _tap(tester, 'cloud-credential-complete');
      await _tap(tester, 'cloud-credential-editor-review');
      expect(h.api.reviews.length, 1);
      expect(find.textContaining(_secret), findsNothing);
      expect(h.api.writes, isEmpty);
      await _enter(tester, 'cloud-credential-confirm-target', 'CREATE New ');
      await _tap(tester, 'cloud-credential-confirm-impact');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('cloud-credential-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await _enter(tester, 'cloud-credential-confirm-target', 'CREATE New');
      await _tap(tester, 'cloud-credential-confirm-submit');
      expect(h.api.writes.length, 1);
      expect(h.api.receivedInput?.disposed, true);
    },
  );
  testWidgets('rename has no secret editor fields and sends no input', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'cloud-credential-rename-4');
    expect(find.byKey(const Key('cloud-credential-secret-key')), findsNothing);
    await _enter(tester, 'cloud-credential-name', 'Renamed');
    await _tap(tester, 'cloud-credential-editor-review');
    await _enter(
      tester,
      'cloud-credential-confirm-target',
      'RENAME 4 Spare S3',
    );
    await _tap(tester, 'cloud-credential-confirm-impact');
    await _tap(tester, 'cloud-credential-confirm-submit');
    expect(h.api.writes.length, 1);
    expect(h.api.receivedInput, isNull);
  });
  testWidgets('invalid secret input remains local with fixed validation', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _createEditor(tester);
    await _enter(
      tester,
      'cloud-credential-endpoint',
      'http://insecure.example',
    );
    await _tap(tester, 'cloud-credential-editor-review');
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
    expect(find.textContaining('Use a bare HTTPS'), findsOneWidget);
  });
  for (final phase in ['editor', 'review']) {
    testWidgets('$phase permanently expires across disconnect/reselection', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _createEditor(tester);
      if (phase == 'review') {
        await _tap(tester, 'cloud-credential-editor-review');
      }
      h.select(null);
      await tester.pumpAndSettle();
      expect(
        find.text(phase == 'editor' ? 'Editor expired' : 'Review expired'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('cloud-credential-secret-key')),
        findsNothing,
      );
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(
        find.text(phase == 'editor' ? 'Editor expired' : 'Review expired'),
        findsOneWidget,
      );
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('inventory reload expires held review without submitting', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _createEditor(tester);
    await _tap(tester, 'cloud-credential-editor-review');
    h.container.invalidate(cloudCredentialsInventoryProvider);
    await tester.pumpAndSettle();
    expect(find.text('Review expired'), findsOneWidget);
    expect(h.api.writes, isEmpty);
  });
  for (final width in [320.0, 430.0]) {
    testWidgets('create editor and review fit $width at 200% above keyboard', (
      tester,
    ) async {
      final h = await _pump(tester, width: width, scale: 2, keyboard: 300);
      expect(tester.takeException(), isNull);
      await _createEditor(tester);
      expect(tester.takeException(), isNull);
      await _tap(tester, 'cloud-credential-editor-review');
      expect(tester.takeException(), isNull);
      await _enter(tester, 'cloud-credential-confirm-target', 'CREATE New');
      await _tap(tester, 'cloud-credential-confirm-impact');
      await _tap(tester, 'cloud-credential-confirm-submit');
      expect(tester.takeException(), isNull);
      expect(h.api.writes.length, 1);
    });
  }
  testWidgets('light theme page fits small viewport', (tester) async {
    await _pump(tester, width: 320, light: true);
    expect(tester.takeException(), isNull);
  });
  test('preview consumes secret input but rejects every operation', () async {
    final api = _Preview(),
        input = _input(),
        inventory = CloudCredentialsPreviewAdapter.inventory;
    final r = await api.reviewCloudCredential(
      CloudCredentialRequest(
        inventory: inventory,
        action: CloudCredentialAction.replace,
        credential: inventory.credentials.last,
      ),
    );
    expect(
      (await api.executeCloudCredential(r, r.target, input: input)).outcome,
      CloudCredentialOutcome.rejected,
    );
    expect(input.disposed, true);
  });
}

class _Preview with CloudCredentialsPreviewAdapter {}
