import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/nvme/nvme_host_authentication_panel.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _secret = 'fixture-private-auth-value';

class _ActiveSession extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession value) => state = value;
}

final _activeSessionProvider =
    NotifierProvider<_ActiveSession, AuthenticatedSession?>(_ActiveSession.new);
Map<String, Object?> _row(
  int id, {
  bool host = false,
  bool controller = false,
  String? group,
  String hash = 'SHA-256',
}) => {
  'id': id,
  'hostnqn': 'nqn.2026-09.example:host$id',
  'dhchap_key': host ? _secret : null,
  'dhchap_ctrl_key': controller ? _secret : null,
  'dhchap_dhgroup': group,
  'dhchap_hash': hash,
};

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostAuthenticationSession {
  _Fake({bool supported = true})
    : adminCatalog = AdminCatalog.fromMetadata(
        version: '25.10.1',
        metadata: {
          if (supported)
            'nvmet.host.query': {
              'accepts': <Object?>[],
              'returns': [
                {'type': 'array'},
              ],
              'job': false,
              'filterable': true,
              'no_auth_required': false,
              'uploadable': false,
              'downloadable': false,
              'roles': ['READONLY_ADMIN'],
            },
        },
      );
  @override
  final AdminCatalog adminCatalog;
  int reads = 0;
  bool fail = false;
  Completer<NvmeHostAuthenticationInventory>? pending;
  List<Map<String, Object?>> rows = [
    _row(1),
    _row(2, host: true, hash: 'SHA-384'),
    _row(3, host: true, controller: true, group: '4096-BIT', hash: 'SHA-512'),
    _row(4, controller: true),
  ];
  @override
  Future<NvmeHostAuthenticationInventory> loadNvmeHostAuthentication() async {
    reads++;
    if (pending != null) return pending!.future;
    if (fail) throw StateError(_secret);
    return NvmeHostAuthenticationInventory.project(rows);
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) =>
      throw StateError('Generic calls are forbidden');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AuthenticatedSession _session(_Fake api) => AuthenticatedSession(
  profileId: 'fixture',
  repository: api,
  availableMethodNames: const {},
  endpoint: 'wss://fixture.example/api/current',
);
Finder _key(String suffix) => find.byKey(Key('nvme-host-auth-$suffix'));
Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Fake api, {
  double width = 430,
  bool dark = true,
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      dashboardActiveSessionProvider.overrideWith(
        (ref) => ref.watch(_activeSessionProvider),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(_activeSessionProvider.notifier).select(_session(api));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(child: NvmeHostAuthenticationPanel()),
        ),
      ),
    ),
  );
  return container;
}

Future<void> _tap(WidgetTester tester, String suffix) async {
  await tester.ensureVisible(_key(suffix));
  await tester.tap(_key(suffix));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [320.0, 430.0]) {
    for (final dark in [true, false]) {
      testWidgets(
        'on-demand authentication charts at $width dark=$dark 200 percent',
        (tester) async {
          final api = _Fake();
          await _pump(tester, api, width: width, dark: dark);
          expect(api.reads, 0);
          expect(_key('presence-donut'), findsNothing);
          await _tap(tester, 'load');
          expect(api.reads, 1);
          for (final suffix in [
            'presence-donut',
            'hash-donut',
            'group-donut',
          ]) {
            expect(_key(suffix), findsOneWidget);
          }
          expect(find.text('keys returned unset: 1'), findsOneWidget);
          expect(find.text('host key returned: 1'), findsOneWidget);
          expect(find.text('both keys returned: 1'), findsOneWidget);
          expect(find.text('inconsistent fields: 1'), findsOneWidget);
          await tester.ensureVisible(_key('detail-4'));
          await tester.tap(_key('detail-4'));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Inconsistent returned fields:'),
            findsOneWidget,
          );
          expect(find.textContaining(_secret), findsNothing);
          await tester.ensureVisible(_key('filter'));
          await tester.enterText(_key('filter'), 'host3');
          await tester.pumpAndSettle();
          expect(_key('detail-3'), findsOneWidget);
          expect(_key('detail-4'), findsNothing);
          expect(find.text('inconsistent fields: 1'), findsOneWidget);
          await tester.enterText(_key('filter'), 'no-match');
          await tester.pumpAndSettle();
          expect(
            find.text('No host metadata matches this local filter.'),
            findsOneWidget,
          );
          await tester.enterText(_key('filter'), '3');
          await tester.pumpAndSettle();
          expect(_key('detail-3'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('reload failure hides old charts and never exposes raw failure', (
    tester,
  ) async {
    final api = _Fake();
    await _pump(tester, api);
    await _tap(tester, 'load');
    api.fail = true;
    await _tap(tester, 'reload');
    expect(_key('presence-donut'), findsNothing);
    expect(
      find.textContaining('counts are unknown, not zero.'),
      findsOneWidget,
    );
    expect(find.textContaining(_secret), findsNothing);
    api.fail = false;
    api.rows = [];
    await _tap(tester, 'retry');
    expect(
      find.text('No hosts were returned in this complete bounded inventory.'),
      findsOneWidget,
    );
    expect(api.reads, 3);
  });
  testWidgets('unsupported connection does not read', (tester) async {
    final api = _Fake(supported: false);
    await _pump(tester, api);
    expect(api.reads, 0);
    expect(_key('load'), findsNothing);
    expect(
      find.textContaining('counts are unknown, not zero.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'connection change hides old data and late response cannot appear',
    (tester) async {
      final api = _Fake()..pending = Completer();
      final container = await _pump(tester, api);
      await tester.tap(_key('load'));
      await tester.pump();
      expect(api.reads, 1);
      final next = _Fake();
      container.read(_activeSessionProvider.notifier).select(_session(next));
      await tester.pump();
      api.pending!.complete(NvmeHostAuthenticationInventory.project(api.rows));
      await tester.pumpAndSettle();
      expect(_key('load'), findsOneWidget);
      expect(_key('presence-donut'), findsNothing);
      expect(next.reads, 0);
      expect(find.textContaining(_secret), findsNothing);
      await _tap(tester, 'load');
      expect(next.reads, 1);
      expect(_key('presence-donut'), findsOneWidget);
    },
  );
  testWidgets('successful reload clears local filter and updates counts', (
    tester,
  ) async {
    final api = _Fake();
    await _pump(tester, api);
    await _tap(tester, 'load');
    await tester.ensureVisible(_key('filter'));
    await tester.enterText(_key('filter'), 'host3');
    api.rows = [_row(5)];
    await _tap(tester, 'reload');
    expect(tester.widget<TextField>(_key('filter')).controller!.text, '');
    expect(_key('detail-5'), findsOneWidget);
    expect(_key('detail-3'), findsNothing);
    expect(find.text('keys returned unset: 1'), findsOneWidget);
  });
}
