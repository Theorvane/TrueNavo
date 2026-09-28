import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_host_key_create_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_host_key_create_editor.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _nqn = 'nqn.2026-09.example:new';

class _ActiveSession extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_ActiveSession, AuthenticatedSession?>(
  _ActiveSession.new,
);

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmeHostKeyCreateSession,
        AuthenticatedNvmeHostChoicesSession,
        AuthenticatedNvmeHostAuthenticationClearSession {
  @override
  final adminCatalog = AdminCatalog.fromMetadata(
    version: '25.10.1',
    metadata: {
      for (final name in [
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.host.query',
        'nvmet.host_subsys.query',
        'nvmet.host.create',
        'nvmet.host.dhchap_hash_choices',
        'nvmet.host.dhchap_dhgroup_choices',
      ])
        name: {
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
        },
    },
  );
  final hosts = <Map<String, Object?>>[
    {'id': 9, 'hostnqn': 'nqn.2026-09.example:old'},
  ];
  final mappings = <Map<String, Object?>>[];
  final subsystem = <String, Object?>{
    'id': 2,
    'name': 'unused',
    'subnqn': 'nqn.2026-09.example:unused',
    'allow_any_host': false,
  };
  int writes = 0, reads = 0;
  final requests = <AdminRequest>[];
  String? failure;
  bool incomplete = false;
  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    reads++;
    if (incomplete) throw const NvmeHostException();
    return NvmeHostPublicRows.project(
      [for (final h in hosts) Map.of(h)],
      [for (final m in mappings) Map.of(m)],
    );
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    requests.add(request);
    return AdminCompleted(
      request,
      value: switch (request.method.name) {
        'nvmet.subsys.query' => [Map.of(subsystem)],
        'nvmet.port.query' ||
        'nvmet.namespace.query' ||
        'nvmet.port_subsys.query' => <Object?>[],
        _ => throw StateError('Generic write is forbidden'),
      },
    );
  }

  Completer<void>? choiceGate, createGate;
  int choiceReads = 0;
  bool supportsHash = true;
  NvmeHostAuthentication? target;
  @override
  Future<NvmeHostAuthenticationChoices>
  loadNvmeHostAuthenticationChoices() async {
    choiceReads++;
    await choiceGate?.future;
    if (failure == 'choices throw') throw StateError('PRIVATE_SENTINEL');
    return NvmeHostAuthenticationChoices.project(
      supportsHash ? ['SHA-256'] : [],
      ['2048-BIT'],
    );
  }

  @override
  Future<NvmeHostAuthentication> loadNvmeHostAuthenticationTarget(
    int id,
  ) async {
    if (failure == 'target throw') throw StateError('PRIVATE_SENTINEL');
    final value = target!;
    return failure == 'target drift'
        ? NvmeHostAuthentication(
            id: id,
            nqn: value.nqn,
            hostKeyReturned: false,
            controllerKeyReturned: value.controllerKeyReturned,
            hash: value.hash,
            group: value.group,
          )
        : value;
  }

  @override
  Future<NvmeHostAuthentication> createNvmeHostWithImportedKeys({
    required String hostNqn,
    required String hash,
    required String? group,
    required NvmeHostKeyDraft keys,
  }) async {
    writes++;
    expect(hostNqn, _nqn);
    expect(keys.isDisposed, false);
    try {
      await createGate?.future;
      if (failure == 'throw') throw StateError('PRIVATE_SENTINEL');
      final id = failure == 'reused ID' ? 9 : 45;
      final nqn = failure == 'wrong NQN'
          ? 'nqn.2026-09.example:wrong'
          : hostNqn;
      if (failure != 'absent') hosts.add({'id': id, 'hostnqn': nqn});
      if (failure == 'host drift') {
        hosts.first['hostnqn'] = 'nqn.2026-09.example:drift';
      }
      if (failure == 'topology drift') subsystem['name'] = 'changed';
      if (failure == 'new mapping') {
        mappings.add({
          'id': 3,
          'host': {'id': id},
          'subsys': {'id': 2},
        });
      }
      if (failure == 'readback failure') incomplete = true;
      return target = NvmeHostAuthentication(
        id: id,
        nqn: nqn,
        hostKeyReturned: failure != 'host missing',
        controllerKeyReturned: keys.hasControllerKey,
        hash: failure == 'wrong hash' ? 'SHA-512' : hash,
        group: failure == 'wrong group' ? '8192-BIT' : group,
      );
    } finally {
      keys.dispose();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness() {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = NvmeHostKeyCreateCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      createApi: api,
      choicesApi: api,
      targetApi: api,
      lock: lock,
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final api = _Fake();
  final lock = ServerOperationLock();
  late final AuthenticatedSession session;
  late final NvmeHostKeyCreateCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  Future<NvmeHostKeyCreateResult> execute(
    NvmeHostKeyCreateReview r, {
    String? phrase,
    bool consent = true,
    bool associationConsent = true,
  }) => coordinator.execute(
    r,
    phrase ?? r.confirmation,
    acknowledgeKeyLimitations: consent,
    acknowledgeNoAssociation: associationConsent,
  );
}

String get _key => 'DHHC-1:01:${base64.encode(List.filled(36, 1))}:';
NvmeHostKeyDraft _draft({bool controller = false}) => NvmeHostKeyDraft.import(
  hostKey: _key,
  controllerKey: controller ? _key : null,
);
Future<NvmeHostKeyCreateReview> _prepare(
  _Harness h,
  NvmeHostKeyDraft keys, {
  String? group,
}) => h.coordinator.prepare(_nqn, hash: 'SHA-256', group: group, keys: keys);

void main() {
  test('provider session replacement destroys prepared keys', () async {
    final h = _Harness(), other = _Harness(), keys = _draft();
    final container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith(
          (ref) => ref.watch(_active),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(_active.notifier).select(h.session);
    final subscription = container.listen(
      nvmeHostKeyCreateCoordinatorProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    final coordinator = container.read(nvmeHostKeyCreateCoordinatorProvider)!;
    await coordinator.prepare(_nqn, hash: 'SHA-256', group: null, keys: keys);
    container.read(_active.notifier).select(other.session);
    container.read(nvmeHostKeyCreateCoordinatorProvider);
    expect(keys.isDisposed, true);
    expect(h.api.writes, 0);
  });
  test('provider disposal destroys prepared keys', () async {
    final h = _Harness(), keys = _draft();
    final container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => h.session),
      ],
    );
    container.listen(nvmeHostKeyCreateCoordinatorProvider, (_, _) {});
    final coordinator = container.read(nvmeHostKeyCreateCoordinatorProvider)!;
    await coordinator.prepare(_nqn, hash: 'SHA-256', group: null, keys: keys);
    container.dispose();
    expect(keys.isDisposed, true);
    expect(h.api.writes, 0);
  });
  test('review expiring during awaited preflight sends nothing', () async {
    final h = _Harness(), keys = _draft();
    final review = await _prepare(h, keys);
    h.api.choiceGate = Completer<void>();
    final pending = h.execute(review);
    await Future<void>.delayed(Duration.zero);
    h.clock = h.clock.add(const Duration(minutes: 5));
    h.api.choiceGate!.complete();
    expect((await pending).outcome, NvmeHostKeyCreateOutcome.rejected);
    expect(keys.isDisposed, true);
    expect(h.api.writes, 0);
  });
  testWidgets(
    'connection switch hides review and clears both secret inputs; late review is discarded',
    (tester) async {
      final h = _Harness(), other = _Harness();
      final container = ProviderContainer(
        overrides: [
          dashboardActiveSessionProvider.overrideWith(
            (ref) => ref.watch(_active),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(_active.notifier).select(h.session);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: TrueRAIDTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(child: NvmeHostKeyCreateEditor()),
            ),
          ),
        ),
      );
      Finder key(String suffix) => find.byKey(Key('nvme-key-create-$suffix'));
      Future<void> enter(String suffix, String text) async {
        await tester.ensureVisible(key(suffix));
        await tester.enterText(key(suffix), text);
      }

      await enter('nqn', _nqn);
      await enter('host-key', _key);
      await enter('controller-key', _key);
      await tester.ensureVisible(key('review'));
      await tester.tap(key('review'));
      await tester.pumpAndSettle();
      expect(key('submit'), findsOneWidget);
      await enter('nqn', 'nqn.2026-09.example:changed');
      await tester.pumpAndSettle();
      expect(key('submit'), findsNothing);
      await enter('nqn', _nqn);
      await enter('host-key', _key);
      await enter('controller-key', _key);
      container.read(_active.notifier).select(other.session);
      await tester.pumpAndSettle();
      for (final suffix in ['host-key', 'controller-key']) {
        expect(tester.widget<TextField>(key(suffix)).controller!.text, isEmpty);
      }
      await enter('host-key', _key);
      other.api.choiceGate = Completer<void>();
      await tester.ensureVisible(key('review'));
      await tester.tap(key('review'));
      await tester.pump();
      container.read(_active.notifier).select(h.session);
      await tester.pump();
      other.api.choiceGate!.complete();
      await tester.pumpAndSettle();
      expect(key('submit'), findsNothing);
      expect(h.api.writes + other.api.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('invalid imports are cleared without printing input', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeHostKeyCreateEditor()),
          ),
        ),
      ),
    );
    Finder key(String suffix) => find.byKey(Key('nvme-key-create-$suffix'));
    for (final suffix in ['host-key', 'controller-key']) {
      await tester.ensureVisible(key(suffix));
      await tester.enterText(key(suffix), 'PRIVATE_SENTINEL');
    }
    await tester.ensureVisible(key('review'));
    await tester.tap(key('review'));
    await tester.pumpAndSettle();
    for (final suffix in ['host-key', 'controller-key']) {
      expect(tester.widget<TextField>(key(suffix)).controller!.text, isEmpty);
    }
    expect(find.textContaining('PRIVATE_SENTINEL'), findsNothing);
    expect(h.api.writes, 0);
    expect(h.api.choiceReads, 0);
    expect(tester.takeException(), isNull);
  });
  for (final controller in [false, true]) {
    test(
      'protected registration and readback controller=$controller',
      () async {
        final h = _Harness(), keys = _draft(controller: controller);
        final r = await _prepare(
          h,
          keys,
          group: controller ? '2048-BIT' : null,
        );
        expect(keys.isDisposed, false);
        expect(r.hasControllerKey, controller);
        expect(h.api.writes, 0);
        final result = await h.execute(r);
        expect(result.outcome, NvmeHostKeyCreateOutcome.completed);
        expect(result.message, isNot(contains(_key)));
        expect(keys.isDisposed, true);
        expect(h.api.writes, 1);
        expect(h.api.choiceReads, 2);
        expect(
          h.api.requests.every((r) => r.method.name.endsWith('.query')),
          true,
        );
        expect((await h.execute(r)).outcome, NvmeHostKeyCreateOutcome.rejected);
        expect(h.api.writes, 1);
      },
    );
  }
  for (final reason in [
    'phrase',
    'key consent',
    'association consent',
    'expired',
    'backwards',
    'connection',
    'cancel',
    'disposed',
    'lock',
    'topology drift',
    'host drift',
    'duplicate',
    'choices',
    'choices throw',
    'incomplete',
  ]) {
    test('prewrite $reason rejects and destroys keys', () async {
      final h = _Harness(), keys = _draft();
      final r = await _prepare(h, keys);
      Object? owner;
      switch (reason) {
        case 'expired':
          h.clock = h.clock.add(const Duration(minutes: 5));
        case 'backwards':
          h.clock = h.clock.subtract(const Duration(seconds: 1));
        case 'connection':
          h.current = false;
        case 'cancel':
          h.coordinator.cancel(r);
        case 'disposed':
          h.coordinator.dispose();
        case 'lock':
          owner = h.lock.acquire();
        case 'topology drift':
          h.api.subsystem['name'] = 'drift';
        case 'host drift':
          h.api.hosts.first['hostnqn'] = 'nqn.2026-09.example:drift';
        case 'duplicate':
          h.api.hosts.add({'id': 81, 'hostnqn': _nqn.toUpperCase()});
        case 'choices':
          h.api.supportsHash = false;
        case 'choices throw':
          h.api.failure = reason;
        case 'incomplete':
          h.api.incomplete = true;
      }
      final result = await h.execute(
        r,
        phrase: reason == 'phrase' ? 'wrong' : null,
        consent: reason != 'key consent',
        associationConsent: reason != 'association consent',
      );
      expect(result.outcome, NvmeHostKeyCreateOutcome.rejected);
      expect(result.message, isNot(contains('PRIVATE_SENTINEL')));
      expect(h.api.writes, 0);
      expect(keys.isDisposed, true);
      if (owner != null) h.lock.release(owner);
    });
  }
  for (final failure in [
    'throw',
    'reused ID',
    'wrong NQN',
    'wrong hash',
    'wrong group',
    'host missing',
    'absent',
    'host drift',
    'topology drift',
    'new mapping',
    'readback failure',
    'target drift',
    'target throw',
  ]) {
    test('postwrite $failure fences without retry or secret errors', () async {
      final h = _Harness(), keys = _draft();
      final r = await _prepare(h, keys);
      h.api.failure = failure;
      final result = await h.execute(r);
      expect(result.outcome, NvmeHostKeyCreateOutcome.unknown);
      expect(h.coordinator.locked, true);
      expect(keys.isDisposed, true);
      expect(h.api.writes, 1);
      expect(result.message, isNot(contains('PRIVATE_SENTINEL')));
      final next = _draft();
      await expectLater(_prepare(h, next), throwsStateError);
      expect(next.isDisposed, true);
      expect(h.api.writes, 1);
    });
  }
  test('new review destroys old draft; reuse cannot consume review', () async {
    final h = _Harness(), first = _draft();
    final r = await _prepare(h, first);
    await expectLater(_prepare(h, first), throwsStateError);
    expect(first.isDisposed, false);
    final second = _draft();
    final next = await _prepare(h, second);
    expect(first.isDisposed, true);
    expect((await h.execute(r)).outcome, NvmeHostKeyCreateOutcome.rejected);
    expect(second.isDisposed, false);
    h.coordinator.cancel(next);
    expect(second.isDisposed, true);
  });
  test(
    'foreign reviews and cancel cannot consume another coordinator draft',
    () async {
      final h = _Harness(), other = _Harness(), keys = _draft();
      final r = await _prepare(h, keys);
      other.coordinator.cancel(r);
      expect(
        (await other.execute(r)).outcome,
        NvmeHostKeyCreateOutcome.rejected,
      );
      expect(keys.isDisposed, false);
      expect((await h.execute(r)).outcome, NvmeHostKeyCreateOutcome.completed);
    },
  );
  test(
    'busy preparation rejects second draft without destroying first',
    () async {
      final h = _Harness(), first = _draft(), second = _draft();
      h.api.choiceGate = Completer<void>();
      final pending = _prepare(h, first);
      await Future<void>.delayed(Duration.zero);
      await expectLater(_prepare(h, first), throwsStateError);
      await expectLater(_prepare(h, second), throwsStateError);
      expect(first.isDisposed, false);
      expect(second.isDisposed, true);
      h.api.choiceGate!.complete();
      h.coordinator.cancel(await pending);
      expect(first.isDisposed, true);
    },
  );
  test('disposal during preflight destroys draft and sends nothing', () async {
    final h = _Harness(), keys = _draft();
    h.api.choiceGate = Completer<void>();
    final pending = _prepare(h, keys);
    await Future<void>.delayed(Duration.zero);
    h.coordinator.dispose();
    expect(keys.isDisposed, true);
    h.api.choiceGate!.complete();
    await expectLater(pending, throwsStateError);
    expect(h.api.writes, 0);
  });
  test('connection loss after submission fences original session', () async {
    final h = _Harness(), keys = _draft();
    final r = await _prepare(h, keys);
    h.api.createGate = Completer<void>();
    final pending = h.execute(r);
    while (h.api.writes == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    h.current = false;
    h.api.createGate!.complete();
    expect((await pending).outcome, NvmeHostKeyCreateOutcome.unknown);
    expect(h.coordinator.locked, true);
    expect(keys.isDisposed, true);
  });
  for (final invalid in [
    'bad nqn',
    'bad hash',
    'bad group',
    'no hash',
    'incomplete',
  ]) {
    test('prepare $invalid destroys draft', () async {
      final h = _Harness(), keys = _draft();
      if (invalid == 'no hash') h.api.supportsHash = false;
      if (invalid == 'incomplete') h.api.incomplete = true;
      await expectLater(
        h.coordinator.prepare(
          invalid == 'bad nqn' ? 'bad' : _nqn,
          hash: invalid == 'bad hash' ? 'MD5' : 'SHA-256',
          group: invalid == 'bad group' ? 'bad' : null,
          keys: keys,
        ),
        throwsStateError,
      );
      expect(keys.isDisposed, true);
      expect(h.api.writes, 0);
    });
  }
  for (final dark in [false, true]) {
    for (final width in [320.0, 430.0]) {
      testWidgets(
        'masked import review and consent at $width dark=$dark 200%',
        (tester) async {
          final h = _Harness();
          tester.view.physicalSize = Size(width, 1800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                dashboardActiveSessionProvider.overrideWith((ref) => h.session),
                nvmeHostKeyCreateCoordinatorProvider.overrideWith(
                  (ref) => h.coordinator,
                ),
              ],
              child: MaterialApp(
                theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const Scaffold(
                  body: SingleChildScrollView(child: NvmeHostKeyCreateEditor()),
                ),
              ),
            ),
          );
          Finder key(String suffix) =>
              find.byKey(Key('nvme-key-create-$suffix'));
          Future<void> tap(String suffix) async {
            await tester.ensureVisible(key(suffix));
            await tester.tap(key(suffix));
            await tester.pumpAndSettle();
          }

          for (final suffix in ['host-key', 'controller-key']) {
            final field = tester.widget<TextField>(key(suffix));
            expect(field.obscureText, true);
            expect(field.enableSuggestions, false);
            expect(field.autocorrect, false);
            expect(field.enableIMEPersonalizedLearning, false);
          }
          Future<void> prepare() async {
            await tester.ensureVisible(key('nqn'));
            await tester.enterText(key('nqn'), _nqn);
            await tester.ensureVisible(key('host-key'));
            await tester.enterText(key('host-key'), _key);
            final editable = find.descendant(
              of: key('host-key'),
              matching: find.byType(EditableText),
            );
            final previousEditingState = tester.state<EditableTextState>(
              editable,
            );
            await tap('review');
            expect(previousEditingState.mounted, false);
          }

          await prepare();
          expect(
            tester.widget<TextField>(key('host-key')).controller!.text,
            isEmpty,
          );
          expect(key('submit'), findsOneWidget);
          expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
          await tap('limitations');
          expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
          await tap('no-association');
          await tester.ensureVisible(key('confirmation'));
          await tester.enterText(key('confirmation'), 'wrong');
          await tap('submit');
          expect(h.api.writes, 0);
          await prepare();
          await tap('cancel');
          expect(key('submit'), findsNothing);
          await prepare();
          await tap('limitations');
          await tap('no-association');
          await tester.ensureVisible(key('confirmation'));
          await tester.enterText(
            key('confirmation'),
            'REGISTER NVME HOST $_nqn WITH IMPORTED KEYS',
          );
          await tap('submit');
          expect(h.api.writes, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
