import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_host_key_generate_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_host_key_generate_editor.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

String get _secret => 'DHHC-1:01:${base64Encode(List.filled(36, 7))}:';
const _metadata = {
  'accepts': <Object?>[],
  'returns': [
    {'type': 'object'},
  ],
  'job': false,
  'filterable': false,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['FULL_ADMIN'],
};

class _Wire implements RpcTransport {
  final _incoming = StreamController<String>();
  final requests = <Map<String, dynamic>>[];
  Object? hashes = ['SHA-256'];
  bool advertise = true;
  @override
  Stream<String> get inboundFrames => _incoming.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(request);
    final result = switch (request['method']) {
      'auth.login_ex' => {'response_type': 'SUCCESS'},
      'auth.me' => {'pw_name': 'fixture-user'},
      'system.info' => {'version': '25.10.1'},
      'core.get_methods' => {
        'nvmet.host.dhchap_hash_choices': _metadata,
        if (advertise) 'nvmet.host.generate_key': _metadata,
      },
      'nvmet.host.dhchap_hash_choices' => hashes,
      'nvmet.host.generate_key' => _secret,
      _ => throw StateError('Unexpected request'),
    };
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() => _incoming.close();
}

class _Connector implements RpcConnector {
  _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Api
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostKeyGenerationSession {
  _Api(this.sdk);
  final TrueNasSessionRepository sdk;
  final keys = <NvmeGeneratedHostKey>[];
  Completer<void>? gate;
  final started = Completer<void>();
  bool fail = false;
  int entries = 0;
  @override
  AdminCatalog get adminCatalog => sdk.adminCatalog;
  @override
  Future<NvmeGeneratedHostKey> generateNvmeHostKey({
    required String hash,
    String? nqn,
  }) async {
    entries++;
    if (fail) throw StateError(_secret);
    final key = await sdk.generateNvmeHostKey(hash: hash, nqn: nqn);
    keys.add(key);
    if (!started.isCompleted) started.complete();
    if (gate != null) await gate!.future;
    return key;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Active extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_Active, AuthenticatedSession?>(_Active.new);

class _Harness {
  static Future<_Harness> create({bool advertise = true}) async {
    final h = _Harness();
    h.wire = _Wire()..advertise = advertise;
    h.sdk = TrueNasSessionRepository(
      connector: _Connector(h.wire),
      nvmeHostKeyNow: () => h.now,
    );
    addTearDown(h.sdk.close);
    await h.sdk.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    h.api = _Api(h.sdk);
    h.session = AuthenticatedSession(
      profileId: 'fixture',
      repository: h.api,
      availableMethodNames: const {},
      endpoint: 'https://fixture.example',
      version: '25.10.1',
    );
    h.coordinator = NvmeHostKeyGenerateCoordinator(
      session: h.session,
      api: h.api,
      catalog: h.api.adminCatalog,
      lock: h.lock,
      isCurrent: () => h.current,
    );
    addTearDown(h.coordinator.dispose);
    return h;
  }

  late _Wire wire;
  late TrueNasSessionRepository sdk;
  late _Api api;
  late AuthenticatedSession session;
  late NvmeHostKeyGenerateCoordinator coordinator;
  final lock = ServerOperationLock();
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 28);
  Future<void> generate({
    bool consent = true,
    bool risks = true,
    String phrase = 'GENERATE NVME KEY',
    String hash = 'SHA-256',
    String? nqn,
  }) => coordinator.generate(
    hash: hash,
    nqn: nqn,
    generationConsent: consent,
    exposureRiskConsent: risks,
    phrase: phrase,
  );
  int get generationCalls => wire.requests
      .where((r) => r['method'] == 'nvmet.host.generate_key')
      .length;
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Harness h, {
  bool dark = true,
  double width = 430,
}) async {
  tester.view.physicalSize = Size(width, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      dashboardActiveSessionProvider.overrideWith((ref) => ref.watch(_active)),
    ],
  );
  addTearDown(container.dispose);
  container.read(_active.notifier).select(h.session);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 960),
            textScaler: const TextScaler.linear(2),
          ),
          child: const Scaffold(
            body: SingleChildScrollView(child: NvmeHostKeyGenerateEditor()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _generateInUi(WidgetTester tester) async {
  await _tap(tester, 'nvme-key-gen-consent');
  await _tap(tester, 'nvme-key-gen-risks');
  final phrase = find.byKey(const Key('nvme-key-gen-phrase'));
  await tester.ensureVisible(phrase);
  await tester.enterText(phrase, 'GENERATE NVME KEY');
  await tester.pumpAndSettle();
  await _tap(tester, 'nvme-key-gen-submit');
}

Future<void> _revealInUi(WidgetTester tester) async {
  await _tap(tester, 'nvme-key-gen-exposure');
  await _tap(tester, 'nvme-key-gen-reveal');
}

void main() {
  test('generation uses real SDK and no host configuration methods', () async {
    final h = await _Harness.create();
    await h.generate(nqn: 'nqn.2026-09.example:initiator');
    expect(h.coordinator.hasKey, true);
    expect(
      h.wire.requests
          .where((r) => (r['method'] as String).startsWith('nvmet.'))
          .map((r) => r['method']),
      ['nvmet.host.dhchap_hash_choices', 'nvmet.host.generate_key'],
    );
    expect(h.wire.requests.last['params'], [
      'SHA-256',
      'nqn.2026-09.example:initiator',
    ]);
    expect(
      () => h.coordinator.takeForTransfer(exposureConsent: false),
      throwsA(isA<NvmeHostKeyGenerationException>()),
    );
    expect(h.coordinator.hasKey, true);
    expect(h.coordinator.takeForTransfer(exposureConsent: true), _secret);
    expect(h.api.keys.single.isDisposed, true);
    expect(
      () => h.coordinator.takeForTransfer(exposureConsent: true),
      throwsA(isA<NvmeHostKeyGenerationException>()),
    );
  });
  for (final reason in [
    'consent',
    'risks',
    'phrase',
    'hash',
    'nqn',
    'closed',
    'session',
    'lock',
    'unsupported',
  ]) {
    test('$reason prevents dispatch', () async {
      final h = await _Harness.create(advertise: reason != 'unsupported');
      Object? owner;
      if (reason == 'closed') h.coordinator.dispose();
      if (reason == 'session') h.current = false;
      if (reason == 'lock') owner = h.lock.acquire();
      await expectLater(
        h.generate(
          consent: reason != 'consent',
          risks: reason != 'risks',
          phrase: reason == 'phrase' ? 'wrong' : 'GENERATE NVME KEY',
          hash: reason == 'hash' ? 'MD5' : 'SHA-256',
          nqn: reason == 'nqn' ? 'invalid' : null,
        ),
        throwsA(isA<NvmeHostKeyGenerationException>()),
      );
      expect(h.api.entries, 0);
      expect(h.generationCalls, 0);
      if (owner != null) h.lock.release(owner);
    });
  }
  for (final reason in ['cancel', 'dispose', 'session']) {
    test('$reason discards late key and blocks duplicate generation', () async {
      final h = await _Harness.create();
      h.api.gate = Completer<void>();
      final result = h.generate();
      final rejected = expectLater(
        result,
        throwsA(isA<NvmeHostKeyGenerationException>()),
      );
      await h.api.started.future;
      await expectLater(
        h.generate(),
        throwsA(isA<NvmeHostKeyGenerationException>()),
      );
      if (reason == 'cancel') h.coordinator.cancel();
      if (reason == 'dispose') h.coordinator.dispose();
      if (reason == 'session') h.current = false;
      h.api.gate!.complete();
      await rejected;
      expect(h.coordinator.hasKey, false);
      expect(h.api.keys.single.isDisposed, true);
      expect(h.generationCalls, 1);
      final owner = h.lock.acquire();
      expect(owner, isNotNull);
      h.lock.release(owner!);
    });
  }
  for (final reason in ['cancel', 'dispose', 'session', 'expire']) {
    test('$reason invalidates transfer and wipes envelope', () async {
      final h = await _Harness.create();
      await h.generate();
      if (reason == 'cancel') h.coordinator.cancel();
      if (reason == 'dispose') h.coordinator.dispose();
      if (reason == 'session') h.current = false;
      if (reason == 'expire') h.now = h.now.add(const Duration(minutes: 5));
      expect(
        () => h.coordinator.takeForTransfer(exposureConsent: true),
        throwsA(isA<NvmeHostKeyGenerationException>()),
      );
      expect(h.api.keys.single.isDisposed, true);
    });
  }
  test(
    'safe error releases shared lock without exposing secret or retrying',
    () async {
      final h = await _Harness.create();
      h.api.fail = true;
      await expectLater(
        h.generate(),
        throwsA(
          isA<NvmeHostKeyGenerationException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(h.api.entries, 1);
      expect(h.coordinator.hasKey, false);
      final owner = h.lock.acquire();
      expect(owner, isNotNull);
      h.lock.release(owner!);
    },
  );
  test('replacement generation disposes the old envelope', () async {
    final h = await _Harness.create();
    await h.generate();
    await h.generate();
    expect(h.api.keys.first.isDisposed, true);
    expect(h.api.keys.last.isDisposed, false);
    h.coordinator.cancel();
    expect(h.api.keys.last.isDisposed, true);
  });

  test('fresh advertised subset rejection does not generate a key', () async {
    final h = await _Harness.create();
    h.wire.hashes = ['SHA-512'];
    await expectLater(
      h.generate(),
      throwsA(isA<NvmeHostKeyGenerationException>()),
    );
    expect(h.generationCalls, 0);
    expect(h.coordinator.hasKey, false);
  });

  testWidgets('generation failure cannot render raw secret error', (
    tester,
  ) async {
    final h = await _Harness.create();
    h.api.fail = true;
    await _mount(tester, h);
    await _generateInUi(tester);
    expect(find.text(_secret), findsNothing);
    expect(find.textContaining('Key generation failed'), findsOneWidget);
    expect(h.api.entries, 1);
    expect(find.byKey(const Key('nvme-key-gen-reveal')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unsupported session stays inert on mount', (tester) async {
    final h = await _Harness.create(advertise: false);
    await _mount(tester, h);
    expect(find.textContaining('generation is unavailable'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('nvme-key-gen-submit')))
          .onPressed,
      isNull,
    );
    expect(h.api.entries, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final revealed in [false, true]) {
    testWidgets('covered route discards key revealed=$revealed', (
      tester,
    ) async {
      final h = await _Harness.create();
      await _mount(tester, h);
      await _generateInUi(tester);
      if (revealed) await _revealInUi(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Another page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(h.api.keys.single.isDisposed, true);
      expect(find.text(_secret, skipOffstage: false), findsNothing);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nvme-key-gen-reveal')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final reason in ['discard', 'leave', 'session', 'provider']) {
    testWidgets('$reason removes revealed secret', (tester) async {
      final h = await _Harness.create();
      final container = await _mount(tester, h);
      await _generateInUi(tester);
      await _revealInUi(tester);
      switch (reason) {
        case 'discard':
          await _tap(tester, 'nvme-key-gen-discard');
        case 'leave':
          await tester.pumpWidget(const SizedBox());
        case 'session':
          container
              .read(_active.notifier)
              .select(
                AuthenticatedSession(
                  profileId: 'other',
                  repository: h.api,
                  availableMethodNames: const {},
                  endpoint: 'https://other.example',
                ),
              );
          await tester.pumpAndSettle();
        case 'provider':
          container.invalidate(nvmeHostKeyGenerateCoordinatorProvider);
          await tester.pumpAndSettle();
      }
      expect(find.text(_secret), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final dark in [true, false]) {
    for (final width in [320.0, 430.0]) {
      testWidgets('protected transfer $width dark=$dark at 200 percent', (
        tester,
      ) async {
        final h = await _Harness.create();
        await _mount(tester, h, dark: dark, width: width);
        expect(h.api.entries, 0);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('nvme-key-gen-submit')),
              )
              .onPressed,
          isNull,
        );
        await _generateInUi(tester);
        expect(h.generationCalls, 1);
        expect(find.text(_secret), findsNothing);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('nvme-key-gen-reveal')),
              )
              .onPressed,
          isNull,
        );
        await _revealInUi(tester);
        expect(find.text(_secret), findsOneWidget);
        expect(h.api.keys.single.isDisposed, true);
        expect(find.byKey(const Key('nvme-key-gen-reveal')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 30));
        expect(find.text(_secret), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  for (final reason in [
    'discard',
    'expire',
    'background',
    'leave',
    'session',
  ]) {
    testWidgets('$reason removes hidden key', (tester) async {
      final h = await _Harness.create();
      final container = await _mount(tester, h);
      await _generateInUi(tester);
      switch (reason) {
        case 'discard':
          await _tap(tester, 'nvme-key-gen-discard');
        case 'expire':
          await tester.pump(const Duration(minutes: 5));
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          await tester.pump();
        case 'leave':
          await tester.pumpWidget(const SizedBox());
        case 'session':
          container
              .read(_active.notifier)
              .select(
                AuthenticatedSession(
                  profileId: 'other',
                  repository: h.api,
                  availableMethodNames: const {},
                  endpoint: 'https://other.example',
                ),
              );
          await tester.pumpAndSettle();
      }
      expect(h.api.keys.single.isDisposed, true);
      expect(find.text(_secret), findsNothing);
      if (reason == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('leaving foreground removes revealed secret', (tester) async {
    final h = await _Harness.create();
    await _mount(tester, h);
    await _generateInUi(tester);
    await _revealInUi(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text(_secret), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'cancel during generation disposes late response without revealing it',
    (tester) async {
      final h = await _Harness.create();
      h.api.gate = Completer<void>();
      await _mount(tester, h);
      // Do not pumpAndSettle an unfinished request.
      await _tap(tester, 'nvme-key-gen-consent');
      await _tap(tester, 'nvme-key-gen-risks');
      final phrase = find.byKey(const Key('nvme-key-gen-phrase'));
      await tester.ensureVisible(phrase);
      await tester.enterText(phrase, 'GENERATE NVME KEY');
      await tester.pump();
      final submit = find.byKey(const Key('nvme-key-gen-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      await tester.runAsync(() => h.api.started.future);
      await tester.pump();
      await _tap(tester, 'nvme-key-gen-discard');
      h.api.gate!.complete();
      await tester.pumpAndSettle();
      expect(h.api.keys.single.isDisposed, true);
      expect(find.text(_secret), findsNothing);
      expect(find.byKey(const Key('nvme-key-gen-reveal')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
