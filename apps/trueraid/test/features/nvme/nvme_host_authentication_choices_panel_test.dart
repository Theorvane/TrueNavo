import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/nvme/nvme_host_authentication_choices_panel.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

class _ActiveSession extends Notifier<AuthenticatedSession?> {
  @override
  AuthenticatedSession? build() => null;
  void select(AuthenticatedSession session) => state = session;
}

final _active = NotifierProvider<_ActiveSession, AuthenticatedSession?>(
  _ActiveSession.new,
);
const _private = 'fixture-private-never-displayed';

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostChoicesSession {
  _Fake({bool hashes = true, bool groups = true, String version = '25.10.1'})
    : adminCatalog = AdminCatalog.fromMetadata(
        version: version,
        metadata: {
          if (hashes) 'nvmet.host.dhchap_hash_choices': _metadata,
          if (groups) 'nvmet.host.dhchap_dhgroup_choices': _metadata,
        },
      );
  static const _metadata = {
    'accepts': <Object?>[],
    'returns': [
      {'type': 'array'},
    ],
    'job': false,
    'filterable': false,
    'no_auth_required': false,
    'uploadable': false,
    'downloadable': false,
    'roles': ['READONLY_ADMIN'],
  };
  @override
  final AdminCatalog adminCatalog;
  int reads = 0;
  bool fail = false;
  Completer<NvmeHostAuthenticationChoices>? pending;
  List<String> hashes = ['SHA-512', 'SHA-256'];
  List<String> groups = ['8192-BIT', '2048-BIT'];
  @override
  Future<NvmeHostAuthenticationChoices>
  loadNvmeHostAuthenticationChoices() async {
    reads++;
    if (pending != null) return pending!.future;
    if (fail) throw StateError(_private);
    return NvmeHostAuthenticationChoices.project(hashes, groups);
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) =>
      throw StateError('No generic reads or writes');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AuthenticatedSession _session(_Fake api) => AuthenticatedSession(
  profileId: 'fixture',
  repository: api,
  availableMethodNames: const {},
  endpoint: 'wss://fixture.example/api/current',
);
Finder _key(String suffix) => find.byKey(Key('nvme-auth-choices-$suffix'));
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
      dashboardActiveSessionProvider.overrideWith((ref) => ref.watch(_active)),
    ],
  );
  addTearDown(container.dispose);
  container.read(_active.notifier).select(_session(api));
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
          body: SingleChildScrollView(
            child: NvmeHostAuthenticationChoicesPanel(),
          ),
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
        'on-demand algorithm subsets wrap at $width dark=$dark 200 percent',
        (tester) async {
          final api = _Fake();
          await _pump(tester, api, width: width, dark: dark);
          expect(api.reads, 0);
          await _tap(tester, 'load');
          expect(api.reads, 1);
          for (final value in ['SHA-512', 'SHA-256', '8192-BIT', '2048-BIT']) {
            expect(find.text(value), findsOneWidget);
          }
          expect(find.text('SHA-384'), findsNothing);
          expect(find.text('4096-BIT'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final api in [
    _Fake(hashes: false),
    _Fake(groups: false),
    _Fake(version: '26.04.0'),
  ]) {
    testWidgets(
      'missing algorithm support or unsupported version sends no reads ${api.adminCatalog}',
      (tester) async {
        await _pump(tester, api);
        expect(api.reads, 0);
        expect(_key('load'), findsNothing);
        expect(
          find.textContaining('supported choices are unknown.'),
          findsOneWidget,
        );
      },
    );
  }
  testWidgets(
    'failed reload hides stale choices and raw errors; empty result is explicit',
    (tester) async {
      final api = _Fake();
      await _pump(tester, api);
      await _tap(tester, 'load');
      api.fail = true;
      await _tap(tester, 'reload');
      expect(find.text('SHA-512'), findsNothing);
      expect(
        find.textContaining('supported choices are unknown.'),
        findsOneWidget,
      );
      expect(find.textContaining(_private), findsNothing);
      api.fail = false;
      api.hashes = [];
      api.groups = [];
      await _tap(tester, 'reload');
      expect(find.text('The server returned no hash choices.'), findsOneWidget);
      expect(
        find.text('The server returned no DH group choices.'),
        findsOneWidget,
      );
      expect(api.reads, 3);
    },
  );
  testWidgets(
    'server switch discards pending choices and requires a new explicit load',
    (tester) async {
      final api = _Fake()..pending = Completer();
      final container = await _pump(tester, api);
      await tester.tap(_key('load'));
      await tester.pump();
      expect(api.reads, 1);
      final next = _Fake()..hashes = ['SHA-384'];
      container.read(_active.notifier).select(_session(next));
      await tester.pump();
      api.pending!.complete(
        NvmeHostAuthenticationChoices.project(api.hashes, api.groups),
      );
      await tester.pumpAndSettle();
      expect(next.reads, 0);
      expect(_key('load'), findsOneWidget);
      expect(find.text('SHA-512'), findsNothing);
      await _tap(tester, 'load');
      expect(next.reads, 1);
      expect(find.text('SHA-384'), findsOneWidget);
    },
  );
}
