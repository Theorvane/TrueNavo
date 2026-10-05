import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_host_key_replace_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_host_key_replace_editor.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _nqn = 'nqn.2026-09.example:old';

class _ActiveSession extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_ActiveSession, AuthenticatedSession?>(
  _ActiveSession.new,
);

const _metadata = <String, Object?>{
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
const _methods = [
  'nvmet.subsys.query',
  'nvmet.port.query',
  'nvmet.namespace.query',
  'nvmet.port_subsys.query',
  'nvmet.host.query',
  'nvmet.host_subsys.query',
  'nvmet.host.update',
  'nvmet.host.dhchap_hash_choices',
  'nvmet.host.dhchap_dhgroup_choices',
];
String get _key => 'DHHC-1:01:${base64.encode(List.filled(36, 1))}:';
String get _oldKey => 'DHHC-1:01:${base64.encode(List.filled(36, 2))}:';
NvmeHostKeyDraft _draft({bool controller = false}) => NvmeHostKeyDraft.import(
  hostKey: _key,
  controllerKey: controller ? _key : null,
);

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession,
        AuthenticatedNvmeHostKeyReplaceSession,
        AuthenticatedNvmeHostChoicesSession,
        AuthenticatedNvmeHostAuthenticationClearSession {
  late TrueNasSessionRepository sdk;
  final proofs = <NvmeHostKeyReplacementReview>[];
  @override
  final adminCatalog = AdminCatalog.fromMetadata(
    version: '25.10.1',
    metadata: {for (final name in _methods) name: _metadata},
  );
  final hosts = <Map<String, Object?>>[
    {
      'id': 9,
      'hostnqn': _nqn,
      'dhchap_key': _oldKey,
      'dhchap_ctrl_key': null,
      'dhchap_hash': 'SHA-256',
      'dhchap_dhgroup': null,
    },
    {'id': 12, 'hostnqn': 'nqn.2026-09.example:other'},
  ];
  final mappings = <Map<String, Object?>>[];
  final subsystem = <String, Object?>{
    'id': 2,
    'name': 'unused',
    'subnqn': 'nqn.2026-09.example:unused',
    'allow_any_host': false,
  };
  int writes = 0, sdkEntries = 0, reads = 0, choiceReads = 0;
  final requests = <AdminRequest>[];
  String? failure;
  bool incomplete = false, supportsHash = true;
  Completer<void>? choiceGate, replaceGate, reviewGate;
  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    reads++;
    if (incomplete) throw StateError(_oldKey);
    return NvmeHostPublicRows.project(
      [for (final row in hosts) Map.of(row)],
      [for (final row in mappings) Map.of(row)],
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

  @override
  Future<NvmeHostAuthenticationChoices>
  loadNvmeHostAuthenticationChoices() async {
    choiceReads++;
    await choiceGate?.future;
    if (failure == 'choices throw') throw StateError(_oldKey);
    return NvmeHostAuthenticationChoices.project(
      supportsHash ? ['SHA-256'] : [],
      ['2048-BIT'],
    );
  }

  @override
  Future<NvmeHostKeyReplacementReview> reviewNvmeHostKeyReplacement(
    int id,
  ) async {
    final review = await sdk.reviewNvmeHostKeyReplacement(id);
    proofs.add(review);
    await reviewGate?.future;
    if (failure == 'review topology drift') subsystem['name'] = 'changed';
    return review;
  }

  @override
  Future<NvmeHostAuthentication> loadNvmeHostAuthenticationTarget(
    int id,
  ) async {
    if (writes > 0 && failure == 'target throw') throw StateError(_oldKey);
    final value = await sdk.loadNvmeHostAuthenticationTarget(id);
    if (writes > 0 && failure == 'target drift') {
      return NvmeHostAuthentication(
        id: id,
        nqn: value.nqn,
        hash: value.hash,
        group: value.group,
        hostKeyReturned: false,
        controllerKeyReturned: value.controllerKeyReturned,
      );
    }
    return value;
  }

  @override
  Future<NvmeHostAuthentication> replaceNvmeHostImportedKeys({
    required NvmeHostKeyReplacementReview review,
    required String hash,
    required String? group,
    required NvmeHostKeyDraft keys,
  }) async {
    sdkEntries++;
    await replaceGate?.future;
    final value = await sdk.replaceNvmeHostImportedKeys(
      review: review,
      hash: hash,
      group: group,
      keys: keys,
    );
    if (failure == 'topology drift') subsystem['name'] = 'changed';
    if (failure == 'readback failure') incomplete = true;
    if (failure == 'host drift') {
      hosts.last['hostnqn'] = 'nqn.2026-09.example:changed';
    }
    if (failure == 'new mapping') {
      mappings.add({
        'id': 4,
        'host': {'id': 9},
        'subsys': {'id': 2},
      });
    }
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Wire implements RpcTransport {
  _Wire(this.api);
  final _Fake api;
  final incoming = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  @override
  Stream<String> get inboundFrames => incoming.stream;
  @override
  Future<void> close() async {
    if (!incoming.isClosed) await incoming.close();
  }

  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final method = request['method'];
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'pw_name': 'fixture-user'};
      case 'system.info':
        result = {'version': '25.10.1'};
      case 'core.get_methods':
        result = {for (final name in _methods) name: _metadata};
      case 'nvmet.host.dhchap_hash_choices':
        result = ['SHA-256'];
      case 'nvmet.host.dhchap_dhgroup_choices':
        result = ['2048-BIT'];
      case 'nvmet.host_subsys.query':
        result = [for (final row in api.mappings) Map.of(row)];
      case 'nvmet.host.query':
        final filter = (request['params'] as List).first as List;
        final rows = filter.isEmpty
            ? api.hosts
            : api.hosts.where((h) => h['id'] == (filter.single as List).last);
        result = [for (final row in rows) Map.of(row)];
      case 'nvmet.host.update':
        final params = request['params'] as List;
        expect(params.first, 9);
        final changes = Map<String, Object?>.from(params.last as Map);
        expect(changes.keys.toSet(), {
          'dhchap_key',
          'dhchap_ctrl_key',
          'dhchap_hash',
          'dhchap_dhgroup',
        });
        api.writes++;
        api.hosts.first.addAll(changes);
        final row = Map.of(api.hosts.first);
        switch (api.failure) {
          case 'wrong ID':
            row['id'] = 99;
          case 'wrong NQN':
            row['hostnqn'] = 'nqn.2026-09.example:wrong';
          case 'wrong hash':
            row['dhchap_hash'] = 'SHA-512';
          case 'wrong group':
            row['dhchap_dhgroup'] = '8192-BIT';
          case 'wrong key':
            row['dhchap_key'] = _oldKey;
          case 'redacted result':
            row['dhchap_key'] = '********';
        }
        if (api.failure == 'throw') {
          incoming.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': request['id'],
              'error': {'code': 203, 'message': _oldKey},
            }),
          );
          return;
        }
        result = row;
      default:
        throw StateError('Unexpected fixture method');
    }
    incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }
}

class _Connector implements RpcConnector {
  _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Harness {
  _Harness._() {
    wire = _Wire(api);
    api.sdk = TrueNasSessionRepository(
      connector: _Connector(wire),
      nvmeHostKeyNow: () => clock,
    );
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = NvmeHostKeyReplaceCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      replaceApi: api,
      choicesApi: api,
      targetApi: api,
      lock: lock,
      isCurrent: () => current,
      now: () => clock,
    );
  }
  static Future<_Harness> create() async {
    final h = _Harness._();
    addTearDown(h.api.sdk.close);
    addTearDown(h.coordinator.dispose);
    await h.api.sdk.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    return h;
  }

  final api = _Fake();
  final lock = ServerOperationLock();
  late final _Wire wire;
  late final AuthenticatedSession session;
  late final NvmeHostKeyReplaceCoordinator coordinator;
  DateTime clock = DateTime.now().toUtc();
  bool current = true;
  Future<NvmeHostKeyReplaceReview> prepare(
    NvmeHostKeyDraft keys, {
    int id = 9,
    String hash = 'SHA-256',
    String? group,
  }) => coordinator.prepare(id, hash: hash, group: group, keys: keys);
  Future<NvmeHostKeyReplaceResult> execute(
    NvmeHostKeyReplaceReview review, {
    String? phrase,
    bool limitations = true,
    bool loss = true,
    bool association = true,
  }) => coordinator.execute(
    review,
    phrase ?? review.confirmation,
    acknowledgeKeyLimitations: limitations,
    acknowledgeCredentialLoss: loss,
    acknowledgeNoAssociation: association,
  );
}

void main() {
  test(
    'provider disposal clears both owned buffers and credential proof',
    () async {
      final h = await _Harness.create(), keys = _draft();
      final container = ProviderContainer(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
      );
      container.listen(nvmeHostKeyReplaceCoordinatorProvider, (_, _) {});
      final coordinator = container.read(
        nvmeHostKeyReplaceCoordinatorProvider,
      )!;
      await coordinator.prepare(9, hash: 'SHA-256', group: null, keys: keys);
      container.dispose();
      expect(keys.isDisposed, true);
      expect(h.api.proofs.single.isDisposed, true);
      expect(h.api.writes, 0);
    },
  );
  for (final id in ['009', '+9', '9 ', '9.0']) {
    testWidgets('non-exact host ID $id cannot prepare a credential review', (
      tester,
    ) async {
      final h = await _Harness.create();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          ],
          child: MaterialApp(
            theme: TrueNavoTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(child: NvmeHostKeyReplaceEditor()),
            ),
          ),
        ),
      );
      Finder key(String suffix) => find.byKey(Key('nvme-key-replace-$suffix'));
      await tester.enterText(key('id'), id);
      await tester.ensureVisible(key('host-key'));
      await tester.enterText(key('host-key'), _key);
      await tester.ensureVisible(key('review'));
      await tester.tap(key('review'));
      await tester.pumpAndSettle();
      expect(h.api.proofs, isEmpty);
      expect(h.api.writes, 0);
      expect(
        tester.widget<TextField>(key('host-key')).controller!.text,
        isEmpty,
      );
      expect(key('submit'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('leaving the page disposes the opaque SDK credential proof', (
    tester,
  ) async {
    final h = await _Harness.create();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          nvmeHostKeyReplaceCoordinatorProvider.overrideWithValue(
            h.coordinator,
          ),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeHostKeyReplaceEditor()),
          ),
        ),
      ),
    );
    Finder key(String suffix) => find.byKey(Key('nvme-key-replace-$suffix'));
    await tester.enterText(key('id'), '9');
    await tester.ensureVisible(key('host-key'));
    await tester.enterText(key('host-key'), _key);
    await tester.ensureVisible(key('review'));
    await tester.tap(key('review'));
    await tester.pumpAndSettle();
    expect(h.api.proofs.single.isDisposed, false);
    expect(find.textContaining(_oldKey), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(h.api.proofs.single.isDisposed, true);
    expect(h.api.writes, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'connection switch hides review and clears both secret inputs; late review is discarded',
    (tester) async {
      final h = await _Harness.create(), other = await _Harness.create();
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
            theme: TrueNavoTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(child: NvmeHostKeyReplaceEditor()),
            ),
          ),
        ),
      );
      Finder key(String suffix) => find.byKey(Key('nvme-key-replace-$suffix'));
      Future<void> enter(String suffix, String text) async {
        await tester.ensureVisible(key(suffix));
        await tester.enterText(key(suffix), text);
      }

      await enter('id', '9');
      await enter('host-key', _key);
      await enter('controller-key', _key);
      await tester.ensureVisible(key('review'));
      await tester.tap(key('review'));
      await tester.pumpAndSettle();
      expect(key('submit'), findsOneWidget);
      await enter('id', '12');
      await tester.pumpAndSettle();
      expect(key('submit'), findsNothing);
      await enter('id', '9');
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
    final h = await _Harness.create();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeHostKeyReplaceEditor()),
          ),
        ),
      ),
    );
    Finder key(String suffix) => find.byKey(Key('nvme-key-replace-$suffix'));
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
  test(
    'SDK proof expiring while preparing cannot acquire a fresh app lifetime',
    () async {
      final h = await _Harness.create(), keys = _draft();
      h.api.reviewGate = Completer<void>();
      final pending = h.prepare(keys);
      while (h.api.proofs.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      h.clock = h.clock.add(const Duration(minutes: 5));
      h.api.reviewGate!.complete();
      await expectLater(pending, throwsStateError);
      expect(keys.isDisposed, true);
      expect(h.api.proofs.single.isDisposed, true);
      expect(h.api.writes, 0);
    },
  );
  for (final controller in [false, true]) {
    test(
      'reviewed replacement uses real protected SDK controller=$controller',
      () async {
        final h = await _Harness.create(),
            keys = _draft(controller: controller);
        final review = await h.prepare(
          keys,
          group: controller ? '2048-BIT' : null,
        );
        expect(review.previous.hostKeyReturned, true);
        expect(h.api.writes, 0);
        final result = await h.execute(review);
        expect(result.outcome, NvmeHostKeyReplaceOutcome.completed);
        expect(keys.isDisposed, true);
        expect(h.api.proofs.single.isDisposed, true);
        expect(h.api.writes, 1);
        expect(h.api.hosts.first['hostnqn'], _nqn);
        expect(
          h.api.requests.every((r) => r.method.name.endsWith('.query')),
          true,
        );
        expect(result.message, isNot(contains(_key)));
        expect(result.message, isNot(contains(_oldKey)));
        expect(
          (await h.execute(review)).outcome,
          NvmeHostKeyReplaceOutcome.rejected,
        );
        expect(h.api.writes, 1);
      },
    );
  }
  for (final reason in [
    'phrase',
    'limitations',
    'loss consent',
    'association consent',
    'expired',
    'backwards',
    'connection',
    'cancel',
    'disposed',
    'lock',
    'topology drift',
    'host drift',
    'association',
    'old hash',
    'old group',
    'old controller',
    'choices',
    'choices throw',
    'incomplete',
  ]) {
    test('prewrite $reason rejects and wipes owned keys/proof', () async {
      final h = await _Harness.create(), keys = _draft();
      final review = await h.prepare(keys);
      Object? owner;
      switch (reason) {
        case 'expired':
          h.clock = h.clock.add(const Duration(minutes: 5));
        case 'backwards':
          h.clock = h.clock.subtract(const Duration(seconds: 1));
        case 'connection':
          h.current = false;
        case 'cancel':
          h.coordinator.cancel(review);
        case 'disposed':
          h.coordinator.dispose();
        case 'lock':
          owner = h.lock.acquire();
        case 'topology drift':
          h.api.subsystem['name'] = 'changed';
        case 'host drift':
          h.api.hosts.last['hostnqn'] = 'nqn.2026-09.example:changed';
        case 'association':
          h.api.mappings.add({
            'id': 4,
            'host': {'id': 9},
            'subsys': {'id': 2},
          });
        case 'old hash':
          h.api.hosts.first['dhchap_hash'] = 'SHA-512';
        case 'old group':
          h.api.hosts.first['dhchap_dhgroup'] = '2048-BIT';
        case 'old controller':
          h.api.hosts.first['dhchap_ctrl_key'] = _oldKey;
        case 'choices':
          h.api.supportsHash = false;
        case 'choices throw':
          h.api.failure = reason;
        case 'incomplete':
          h.api.incomplete = true;
      }
      final result = await h.execute(
        review,
        phrase: reason == 'phrase' ? 'wrong' : null,
        limitations: reason != 'limitations',
        loss: reason != 'loss consent',
        association: reason != 'association consent',
      );
      expect(result.outcome, NvmeHostKeyReplaceOutcome.rejected);
      expect(h.api.writes, 0);
      expect(h.api.sdkEntries, 0);
      expect(keys.isDisposed, true);
      expect(h.api.proofs.single.isDisposed, true);
      expect(result.message, isNot(contains(_oldKey)));
      if (owner != null) h.lock.release(owner);
    });
  }
  for (final failure in [
    'throw',
    'wrong ID',
    'wrong NQN',
    'wrong hash',
    'wrong group',
    'wrong key',
    'redacted result',
    'topology drift',
    'host drift',
    'new mapping',
    'readback failure',
    'target drift',
    'target throw',
  ]) {
    test('postwrite $failure fences original session without retry', () async {
      final h = await _Harness.create(), keys = _draft();
      final review = await h.prepare(keys);
      h.api.failure = failure;
      final result = await h.execute(review);
      expect(result.outcome, NvmeHostKeyReplaceOutcome.unknown);
      expect(h.api.writes, 1);
      expect(h.coordinator.locked, true);
      expect(keys.isDisposed, true);
      expect(h.api.proofs.single.isDisposed, true);
      expect(result.message, isNot(contains(_oldKey)));
      final next = _draft();
      await expectLater(h.prepare(next), throwsStateError);
      expect(next.isDisposed, true);
      expect(h.api.writes, 1);
    });
  }
  test('unchanged presence flags with rotated old key fail SDK proof and conservatively fence', () async {
    final h = await _Harness.create(), keys = _draft();
    final review = await h.prepare(keys);
    h.api.hosts.first['dhchap_key'] = _key;
    final result = await h.execute(review);
    expect(result.outcome, NvmeHostKeyReplaceOutcome.unknown);
    expect(h.api.sdkEntries, 1);
    expect(h.api.writes, 0);
    expect(h.coordinator.locked, true);
    expect(keys.isDisposed, true);
    expect(h.api.proofs.single.isDisposed, true);
  });
  for (final invalid in [
    'ID',
    'missing ID',
    'association',
    'bad hash',
    'bad group',
    'review topology drift',
    'incomplete',
  ]) {
    test(
      'preparation rejects $invalid and disposes retained objects',
      () async {
        final h = await _Harness.create(), keys = _draft();
        if (invalid == 'association') {
          h.api.mappings.add({
            'id': 3,
            'host': {'id': 9},
            'subsys': {'id': 2},
          });
        }
        if (invalid == 'review topology drift') h.api.failure = invalid;
        if (invalid == 'incomplete') h.api.incomplete = true;
        await expectLater(
          h.prepare(
            keys,
            id: invalid == 'ID'
                ? 0
                : invalid == 'missing ID'
                ? 99
                : 9,
            hash: invalid == 'bad hash' ? 'MD5' : 'SHA-256',
            group: invalid == 'bad group' ? 'bad' : null,
          ),
          throwsStateError,
        );
        expect(keys.isDisposed, true);
        expect(h.api.proofs.every((p) => p.isDisposed), true);
        expect(h.api.writes, 0);
      },
    );
  }
  test('new review discards old draft and opaque credential proof; reuse cannot consume it', () async {
    final h = await _Harness.create(), first = _draft();
    final old = await h.prepare(first);
    await expectLater(h.prepare(first), throwsStateError);
    expect(first.isDisposed, false);
    final next = _draft();
    final review = await h.prepare(next);
    expect(first.isDisposed, true);
    expect(h.api.proofs.first.isDisposed, true);
    expect((await h.execute(old)).outcome, NvmeHostKeyReplaceOutcome.rejected);
    expect(next.isDisposed, false);
    h.coordinator.cancel(review);
    expect(next.isDisposed, true);
    expect(h.api.proofs.last.isDisposed, true);
  });
  test('foreign coordinator cannot cancel or execute another review', () async {
    final h = await _Harness.create(),
        other = await _Harness.create(),
        keys = _draft();
    final review = await h.prepare(keys);
    other.coordinator.cancel(review);
    expect(
      (await other.execute(review)).outcome,
      NvmeHostKeyReplaceOutcome.rejected,
    );
    expect(keys.isDisposed, false);
    expect(h.api.proofs.single.isDisposed, false);
    expect(
      (await h.execute(review)).outcome,
      NvmeHostKeyReplaceOutcome.completed,
    );
  });
  test(
    'busy preparation preserves first draft and disposes a second',
    () async {
      final h = await _Harness.create(), first = _draft(), second = _draft();
      h.api.choiceGate = Completer<void>();
      final pending = h.prepare(first);
      await Future<void>.delayed(Duration.zero);
      await expectLater(h.prepare(first), throwsStateError);
      await expectLater(h.prepare(second), throwsStateError);
      expect(first.isDisposed, false);
      expect(second.isDisposed, true);
      h.api.choiceGate!.complete();
      h.coordinator.cancel(await pending);
      expect(first.isDisposed, true);
      expect(h.api.proofs.single.isDisposed, true);
    },
  );
  test(
    'disposal while awaiting SDK review destroys late proof and draft',
    () async {
      final h = await _Harness.create(), keys = _draft();
      h.api.reviewGate = Completer<void>();
      final pending = h.prepare(keys);
      while (h.api.proofs.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      h.coordinator.dispose();
      h.api.reviewGate!.complete();
      await expectLater(pending, throwsStateError);
      expect(keys.isDisposed, true);
      expect(h.api.proofs.single.isDisposed, true);
      expect(h.api.writes, 0);
    },
  );
  test('review expiring during awaited preflight sends nothing', () async {
    final h = await _Harness.create(), keys = _draft();
    final review = await h.prepare(keys);
    h.api.choiceGate = Completer<void>();
    final pending = h.execute(review);
    await Future<void>.delayed(Duration.zero);
    h.clock = h.clock.add(const Duration(minutes: 5));
    h.api.choiceGate!.complete();
    expect((await pending).outcome, NvmeHostKeyReplaceOutcome.rejected);
    expect(h.api.writes, 0);
    expect(keys.isDisposed, true);
  });
  test(
    'connection replacement after SDK entry fences original session',
    () async {
      final h = await _Harness.create(), keys = _draft();
      final review = await h.prepare(keys);
      h.api.replaceGate = Completer<void>();
      final pending = h.execute(review);
      while (h.api.sdkEntries == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      h.current = false;
      h.api.replaceGate!.complete();
      expect((await pending).outcome, NvmeHostKeyReplaceOutcome.unknown);
      expect(h.coordinator.locked, true);
      expect(h.api.writes, 1);
      expect(keys.isDisposed, true);
    },
  );
  test('provider session change disposes review and keys', () async {
    final h = await _Harness.create(),
        other = await _Harness.create(),
        keys = _draft();
    final container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith(
          (ref) => ref.watch(_active),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(_active.notifier).select(h.session);
    final sub = container.listen(
      nvmeHostKeyReplaceCoordinatorProvider,
      (_, _) {},
    );
    addTearDown(sub.close);
    final coordinator = container.read(nvmeHostKeyReplaceCoordinatorProvider)!;
    await coordinator.prepare(9, hash: 'SHA-256', group: null, keys: keys);
    container.read(_active.notifier).select(other.session);
    container.read(nvmeHostKeyReplaceCoordinatorProvider);
    expect(keys.isDisposed, true);
    expect(h.api.proofs.single.isDisposed, true);
    expect(h.api.writes, 0);
  });
  for (final dark in [false, true]) {
    for (final width in [320.0, 430.0]) {
      testWidgets(
        'masked import review and consent at $width dark=$dark 200%',
        (tester) async {
          final h = await _Harness.create();
          tester.view.physicalSize = Size(width, 1800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                dashboardActiveSessionProvider.overrideWith((ref) => h.session),
                nvmeHostKeyReplaceCoordinatorProvider.overrideWith(
                  (ref) => h.coordinator,
                ),
              ],
              child: MaterialApp(
                theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const Scaffold(
                  body: SingleChildScrollView(
                    child: NvmeHostKeyReplaceEditor(),
                  ),
                ),
              ),
            ),
          );
          Finder key(String suffix) =>
              find.byKey(Key('nvme-key-replace-$suffix'));
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
            await tester.ensureVisible(key('id'));
            await tester.enterText(key('id'), '9');
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
          expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
          await tap('credential-loss');
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
          expect(tester.widget<FilledButton>(key('submit')).onPressed, isNull);
          await tap('credential-loss');
          await tester.ensureVisible(key('confirmation'));
          await tester.enterText(
            key('confirmation'),
            'REPLACE NVME HOST 9 KEYS',
          );
          await tap('submit');
          expect(h.api.writes, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
