import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/admin/admin_schema_form.dart';
import 'package:trueraid/features/apps/app_install_page.dart';
import 'package:trueraid/features/apps/apps_controller.dart';
import 'package:trueraid/features/apps/apps_page.dart';
import 'package:trueraid/features/apps/apps_status_chart.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test('review enumerates all leaves including empty containers', () {
    expect(
      appSettingsReviewLines({
        'port': 30000,
        'paths': ['/mnt/tank'],
        'secret': '[redacted]',
        'empty': <String, Object?>{},
      }),
      ['port: 30000', 'paths[0]: /mnt/tank', 'secret: [redacted]', 'empty: {}'],
    );
  });
  test('oversized settings cannot silently disappear from review', () {
    expect(
      () => appSettingsReviewLines(List.filled(201, 1)),
      throwsFormatException,
    );
    expect(() => appSettingsReviewLines('x' * 16001), throwsFormatException);
  });
  testWidgets('inventory renders health counts and performs no writes', (
    tester,
  ) async {
    final h = await _pump(tester);
    expect(h.api.reads, 1);
    expect(find.text('Running · 1'), findsOneWidget);
    expect(find.text('Stopped · 0'), findsOneWidget);
    expect(h.api.actions, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'installed notes and portals load only after explicit expansion',
    (tester) async {
      final h = await _pump(tester);
      expect(h.api.detailsReads, 0);
      await _tap(tester, find.byKey(const ValueKey('app-details-media')));
      expect(h.api.detailsReads, 1);
      expect(find.text('Operator note'), findsOneWidget);
      expect(find.text('https://nas.example:3000/ui'), findsOneWidget);
      expect(h.api.actions, isEmpty);
      await _tap(tester, find.byKey(const ValueKey('app-details-media')));
      expect(find.text('Operator note'), findsNothing);
    },
  );
  testWidgets('account change hides old notes and needs a new expansion', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const ValueKey('app-details-media')));
    expect(find.text('Operator note'), findsOneWidget);
    final next = _FakeApps()..displayNotes = 'Other account note';
    h.active = AuthenticatedSession(
      profileId: 'other-account',
      repository: next,
      availableMethodNames: _methods,
      version: '25.10.1',
      endpoint: 'wss://other.example/api/current',
    );
    h.container.invalidate(dashboardActiveSessionProvider);
    await tester.pumpAndSettle();
    expect(find.text('Operator note'), findsNothing);
    expect(find.text('Other account note'), findsNothing);
    expect(next.detailsReads, 0);
    await _tap(tester, find.byKey(const ValueKey('app-details-media')));
    expect(find.text('Other account note'), findsOneWidget);
    expect(next.detailsReads, 1);
  });
  testWidgets('start and stop have independent method permission gates', (
    tester,
  ) async {
    await _pump(tester, methods: const {'app.stop'});
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('app-stop-media')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('app-redeploy-media')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('app-uninstall-media')))
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'uninstall requires exact target and warns about Docker volumes',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, find.byKey(const Key('app-uninstall-media')));
      expect(find.textContaining('Docker-managed volumes may'), findsOneWidget);
      expect(h.api.actions, isEmpty);
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'MEDIA',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('app-confirm-submit')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'media',
      );
      await _tap(tester, find.byKey(const Key('app-confirm-submit')));
      expect(h.api.actions, ['delete']);
      expect(h.api.deleted?.app, same(h.api.installed));
    },
  );
  testWidgets('catalog can be searched without installing anything', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    expect(find.text('Sample media server'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('apps-search-true')),
      'not-present',
    );
    await tester.pumpAndSettle();
    expect(
      find.text('No catalog applications match these filters.'),
      findsOneWidget,
    );
    expect(h.api.actions, isEmpty);
  });
  testWidgets(
    'catalog shows server trains and preferred settings without a write',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
      expect(
        find.text('Server trains: stable, community · Preferred: stable'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('apps-train-community')),
        findsOneWidget,
      );
      expect(find.text('stable · preferred'), findsOneWidget);
      expect(h.api.overviewReads, 1);
      expect(h.api.actions, isEmpty);
    },
  );
  testWidgets('catalog preference needs confirmation before a fake update', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    await _tap(
      tester,
      find.byKey(const ValueKey('catalog-preference-community')),
    );
    await _tap(tester, find.byKey(const Key('catalog-preferences-save')));
    expect(h.api.actions, isEmpty);
    expect(find.textContaining('Requested: stable, community'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('app-confirm-name')),
      'catalog preferences',
    );
    await _tap(tester, find.byKey(const Key('app-confirm-submit')));
    expect(h.api.actions, ['catalog.update']);
    expect(h.api.preferredTrains, ['stable', 'community']);
  });
  testWidgets('catalog preference cancel sends no update', (tester) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    await _tap(
      tester,
      find.byKey(const ValueKey('catalog-preference-community')),
    );
    await _tap(tester, find.byKey(const Key('catalog-preferences-save')));
    await _tap(tester, find.text('Cancel'));
    expect(h.api.actions, isEmpty);
  });
  testWidgets('unavailable preferred train can be removed but not re-added', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.api.preferredTrains = ['stable', 'retired'];
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    expect(find.text('retired · unavailable'), findsOneWidget);
    expect(
      find.text('Remove unavailable preferred trains before saving.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('catalog-preferences-save')),
          )
          .onPressed,
      isNull,
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('catalog-preference-retired')),
    );
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('catalog-preference-retired')),
          )
          .onSelected,
      isNull,
    );
    await _tap(tester, find.byKey(const Key('catalog-preferences-save')));
    await tester.enterText(
      find.byKey(const Key('app-confirm-name')),
      'catalog preferences',
    );
    await _tap(tester, find.byKey(const Key('app-confirm-submit')));
    expect(h.api.preferredTrains, ['stable']);
    expect(h.api.actions, ['catalog.update']);
  });
  testWidgets('catalog update without method permission has no editor', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      methods: _methods.difference({'catalog.update'}),
    );
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    expect(find.byKey(const Key('catalog-preferences-save')), findsNothing);
    expect(h.api.actions, isEmpty);
  });
  testWidgets(
    'catalog sync requires exact confirmation and tracks one fake job',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
      await _tap(tester, find.byKey(const Key('catalog-sync')));
      expect(h.api.actions, isEmpty);
      expect(
        find.textContaining('fetch upstream catalog changes'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'catalog sync',
      );
      await _tap(tester, find.byKey(const Key('app-confirm-submit')));
      expect(h.api.actions, ['catalog.sync']);
      expect(h.container.read(appsControllerProvider).pending, isTrue);
      await h.container.read(appsControllerProvider.notifier).checkJob();
      await tester.pump();
      expect(h.api.syncPolls, 1);
      expect(
        h.container.read(appsControllerProvider).result?.outcome,
        AppOperationOutcome.verified,
      );
    },
  );
  testWidgets('cached-only list cannot trigger catalog sync', (tester) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    await _tap(tester, find.byKey(const Key('apps-cached-catalog-only')));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('catalog-sync')))
          .onPressed,
      isNull,
    );
    expect(h.api.actions, isEmpty);
  });
  testWidgets('catalog category train recommendation and tag filters compose', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.api.catalogEntries = [
      h.api.catalog,
      CatalogApp(
        name: 'archive',
        train: 'stable',
        title: 'Archive tool',
        description: 'Protect files.',
        categories: ['Data'],
        tags: ['backup'],
        healthy: true,
        supported: true,
      ),
      CatalogApp(
        name: 'lab',
        train: 'community',
        title: 'Lab tool',
        description: 'Experiment.',
        categories: ['Media'],
        tags: ['testing'],
        healthy: true,
        supported: true,
      ),
    ];
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    expect(find.text('3 catalog applications'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('apps-category-Media')));
    expect(find.text('2 catalog applications'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('apps-train-stable')));
    expect(find.text('2 catalog applications'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('apps-category-Media')));
    expect(find.text('1 catalog applications'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('apps-recommended-only')));
    expect(find.text('Sample media server'), findsOneWidget);
    expect(find.text('Archive tool'), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('apps-train-community')));
    expect(
      find.text('No catalog applications match these filters.'),
      findsOneWidget,
    );
    await _tap(tester, find.byKey(const Key('apps-recommended-only')));
    expect(find.text('Lab tool'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('apps-train-all')));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('apps-search-true')),
      -250,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 50,
    );
    await tester.enterText(
      find.byKey(const ValueKey('apps-search-true')),
      'backup',
    );
    await tester.pumpAndSettle();
    expect(find.text('Archive tool'), findsOneWidget);
    expect(find.text('Sample media server'), findsNothing);
    expect(h.api.actions, isEmpty);
  });
  testWidgets('catalog refresh does not strand a removed category', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    await _tap(tester, find.byKey(const ValueKey('apps-category-Media')));
    h.api.catalogEntries = [
      CatalogApp(
        name: 'archive',
        train: 'stable',
        title: 'Archive tool',
        description: 'Protect files.',
        categories: ['Data'],
        healthy: true,
        supported: true,
      ),
    ];
    h.container.invalidate(appsCatalogProvider(false));
    await tester.pumpAndSettle();
    expect(find.text('Archive tool'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('apps-category-all')))
          .selected,
      isTrue,
    );
    expect(h.api.actions, isEmpty);
  });
  testWidgets('server-cached list is explicit and never opens installer', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    expect(h.api.catalogReadModes, [false]);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('catalog-open-stable-media')),
          )
          .onPressed,
      isNotNull,
    );
    await _tap(tester, find.byKey(const Key('apps-cached-catalog-only')));
    expect(h.api.catalogReadModes, [false, true]);
    expect(find.text('Server-cached list only'), findsOneWidget);
    expect(
      find.textContaining('Requires this server connection'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('catalog-open-stable-media')),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('Switch off server-cached'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('apps-cached-catalog-only')));
    expect(h.api.catalogReadModes, [false, true, false]);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('catalog-open-stable-media')),
          )
          .onPressed,
      isNotNull,
    );
    expect(h.api.actions, isEmpty);
  });
  testWidgets('new account cannot see previous catalogue while loading', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    expect(find.text('Sample media server'), findsOneWidget);
    final next = _FakeApps();
    final pending = Completer<List<CatalogApp>>();
    next.pendingCatalog = pending.future;
    h.active = AuthenticatedSession(
      profileId: 'other-account',
      repository: next,
      availableMethodNames: _methods,
      version: '25.10.1',
      endpoint: 'wss://other.example/api/current',
    );
    h.container.invalidate(dashboardActiveSessionProvider);
    await tester.pump();
    expect(find.text('Sample media server'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    pending.complete([
      CatalogApp(
        name: 'other',
        train: 'stable',
        title: 'Other account application',
        description: '',
        healthy: true,
        supported: true,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Other account application'), findsOneWidget);
    expect(find.text('Sample media server'), findsNothing);
  });
  testWidgets(
    'install review preserves ports and paths but never echoes secret',
    (tester) async {
      final h = await _pump(tester, install: true);
      await _selectVersion(tester);
      final secret = find.byKey(const ValueKey('admin-value-values.password'));
      await _reveal(tester, secret);
      await tester.enterText(secret, 'sample-private-value');
      await _tap(tester, find.byKey(const Key('app-review-install')));
      expect(find.text('port: 30000'), findsOneWidget);
      expect(find.text('mount: /mnt/tank/media'), findsOneWidget);
      expect(find.text('password: [redacted]'), findsOneWidget);
      expect(find.text('password: sample-private-value'), findsNothing);
      expect(h.api.actions, isEmpty);
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'media',
      );
      await _tap(tester, find.byKey(const Key('app-confirm-submit')));
      expect(h.api.actions, ['install']);
      expect(h.api.created!.values, {
        'port': 30000,
        'mount': '/mnt/tank/media',
        'password': 'sample-private-value',
      });
      await _reveal(tester, secret);
      expect(tester.widget<TextField>(secret).controller!.text, isEmpty);
    },
  );
  testWidgets('upgrade reviews server release notes with no install defaults', (
    tester,
  ) async {
    final h = await _pump(tester, upgrade: true);
    expect(find.byKey(const Key('app-install-name')), findsNothing);
    await _selectVersion(tester);
    expect(find.byType(AdminSchemaForm), findsNothing);
    expect(find.text('Server-provided migration notes.'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('app-review-upgrade')));
    expect(
      find.textContaining('No configuration overrides will be sent.'),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const Key('app-confirm-name')), 'media');
    await _tap(tester, find.byKey(const Key('app-confirm-submit')));
    expect(h.api.actions, ['upgrade']);
    expect(h.api.upgraded!.values, isEmpty);
    expect(h.api.upgraded!.review, same(h.api.review));
  });
  testWidgets('a changed authenticated session cancels pending review', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const Key('app-uninstall-media')));
    h.active = null;
    h.container.invalidate(dashboardActiveSessionProvider);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('app-confirm-name')), 'media');
    await _tap(tester, find.byKey(const Key('app-confirm-submit')));
    expect(h.api.actions, isEmpty);
  });
  testWidgets('applications and health ring fit 320px at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(tester, scale: 2);
    await tester.drag(find.byType(ListView).first, const Offset(0, -1400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty health ring reports zero without percentage fiction', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueRAIDTheme.dark(),
        home: const Scaffold(body: AppsStatusChart(states: [])),
      ),
    );
    expect(
      find.bySemanticsLabel(
        '0 applications; 0 running, 0 stopped, 0 other states.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('%'), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('catalog and install navigation fit 320px at 200 percent text', (
    tester,
  ) async {
    _compactView(tester);
    final h = await _pump(tester, scale: 2);
    await _tap(tester, find.byKey(const Key('apps-catalog-tab')));
    await _reveal(
      tester,
      find.byKey(const ValueKey('catalog-open-stable-media')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sample media server'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, find.byKey(const ValueKey('catalog-open-stable-media')));
    await _reveal(tester, find.byKey(const Key('app-install-name')));
    expect(find.byKey(const Key('app-install-name')), findsOneWidget);
    await _selectVersion(tester);
    await _reveal(tester, find.byKey(const Key('app-review-install')));
    await tester.pumpAndSettle();
    expect(find.byType(AdminSchemaForm), findsOneWidget);
    expect(h.api.actions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelled install review fits compact text and clears every entered secret',
    (tester) async {
      _compactView(tester);
      final h = await _pump(tester, install: true, scale: 2);
      await _selectVersion(tester);
      final secret = find.byKey(const ValueKey('admin-value-values.password'));
      await _reveal(tester, secret);
      await tester.enterText(secret, 'cancelled-private-value');
      await _tap(tester, find.byKey(const Key('app-review-install')));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('password: [redacted]'), findsOneWidget);
      expect(find.text('password: cancelled-private-value'), findsNothing);
      await _reveal(tester, find.byKey(const Key('app-confirm-name')));
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'media',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('Cancel'));
      await _reveal(tester, secret);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(secret).controller!.text, isEmpty);
      expect(
        tester
            .state<AdminSchemaFormState>(find.byType(AdminSchemaForm))
            .hasSensitiveValues,
        isFalse,
      );
      expect(h.api.created, isNull);
      expect(h.api.actions, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'upgrade release notes and review fit 320px at 200 percent text',
    (tester) async {
      _compactView(tester);
      final h = await _pump(tester, upgrade: true, scale: 2);
      await _selectVersion(tester);
      await _reveal(tester, find.text('Server-provided migration notes.'));
      await tester.pumpAndSettle();
      expect(find.byType(AdminSchemaForm), findsNothing);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.byKey(const Key('app-review-upgrade')));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.textContaining('No configuration overrides will be sent.'),
        findsOneWidget,
      );
      await _reveal(tester, find.byKey(const Key('app-confirm-name')));
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'media',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('Cancel'));
      expect(h.api.actions, isEmpty);
      expect(h.api.upgraded, isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

void _compactView(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 50,
    );
  }
  await tester.ensureVisible(finder);
}

Future<void> _selectVersion(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('app-version')));
  await _tap(tester, find.text('2.0.0').last);
}

const _methods = {
  'app.create',
  'app.stop',
  'app.start',
  'app.redeploy',
  'app.delete',
  'app.upgrade',
  'app.upgrade_summary',
  'catalog.trains',
  'catalog.config',
  'catalog.update',
  'catalog.sync',
};
Future<_Harness> _pump(
  WidgetTester tester, {
  bool install = false,
  bool upgrade = false,
  double scale = 1,
  Set<String> methods = _methods,
}) async {
  final h = _Harness(methods);
  addTearDown(h.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueRAIDTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: install || upgrade
            ? AppInstallPage(
                session: h.session,
                app: h.api.catalog,
                upgrading: upgrade ? h.api.installed : null,
              )
            : const AppsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

class _Harness {
  _Harness(Set<String> methods) {
    session = AuthenticatedSession(
      profileId: 'test',
      repository: api,
      availableMethodNames: methods,
      version: '25.10.1',
      endpoint: 'wss://sample.example/api/current',
    );
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final api = _FakeApps();
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
}

class _FakeApps
    implements
        SessionRepository,
        AuthenticatedAppsSession,
        AuthenticatedCatalogOverviewSession {
  final actions = <String>[];
  var reads = 0;
  var detailsReads = 0;
  String displayNotes = 'Operator note';
  var overviewReads = 0;
  var syncPolls = 0;
  List<String> preferredTrains = ['stable'];
  AppInstallRequest? created;
  AppUpgradeRequest? upgraded;
  AppUninstallRequest? deleted;
  final installed = const InstalledApp(
    id: 'media',
    name: 'media',
    state: 'RUNNING',
    version: '1.0.0',
    catalogApp: 'media',
    train: 'stable',
    customApp: false,
    upgradeAvailable: true,
  );
  final catalog = CatalogApp(
    name: 'media',
    train: 'stable',
    title: 'Sample media server',
    description: 'A sample catalog application.',
    categories: ['Media'],
    tags: ['streaming'],
    recommended: true,
    healthy: true,
    supported: true,
  );
  List<CatalogApp>? catalogEntries;
  Future<List<CatalogApp>>? pendingCatalog;
  final catalogReadModes = <bool>[];
  late final details = AppVersionDetails(
    app: catalog,
    version: '2.0.0',
    humanVersion: '2.0.0',
    formSchema: AppFormSchema.fromQuestions([
      {
        'variable': 'port',
        'schema': {'type': 'int', 'required': true, 'default': 30000},
      },
      {
        'variable': 'mount',
        'schema': {
          'type': 'hostpath',
          'required': true,
          'default': '/mnt/tank/media',
        },
      },
      {
        'variable': 'password',
        'schema': {'type': 'string', 'required': true, 'private': true},
      },
    ]),
    warnings: [],
  );
  late final review = AppUpgradeReview(
    app: installed,
    details: details,
    changelog: 'Server-provided migration notes.',
    humanVersion: '2.0.0',
  );
  @override
  AppsCapabilities get appsCapabilities => const AppsCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
  );
  @override
  Future<AppsInventory> loadAppsInventory() async {
    reads++;
    return AppsInventory(
      apps: [installed],
      pool: 'tank',
      dockerStatus: 'RUNNING',
    );
  }

  @override
  Future<InstalledAppDetails> loadInstalledAppDetails(InstalledApp app) async {
    detailsReads++;
    return InstalledAppDetails(
      app: app,
      notes: displayNotes,
      portals: {'Web UI': 'https://nas.example:3000/ui'},
    );
  }

  @override
  Future<List<CatalogApp>> loadAppsCatalog({bool cachedOnly = false}) async {
    catalogReadModes.add(cachedOnly);
    return await pendingCatalog ?? catalogEntries ?? [catalog];
  }

  @override
  Future<CatalogOverview> loadCatalogOverview() async {
    overviewReads++;
    return CatalogOverview(
      availableTrains: ['stable', 'community'],
      preferredTrains: preferredTrains,
    );
  }

  @override
  Future<AppOperationResult> updateCatalogPreferredTrains(
    CatalogOverview overview,
    List<String> desired,
  ) async {
    actions.add('catalog.update');
    preferredTrains = List<String>.of(desired);
    return _verified;
  }

  @override
  Future<AppOperationResult> syncCatalog(CatalogOverview overview) async {
    actions.add('catalog.sync');
    return const AppOperationResult(
      outcome: AppOperationOutcome.submitted,
      job: AppJob(id: 808, appName: 'catalog', operation: 'catalog.sync'),
    );
  }

  @override
  Future<List<String>> loadAppVersions(CatalogApp app) async => ['2.0.0'];
  @override
  Future<AppVersionDetails> loadAppVersionDetails(
    CatalogApp app,
    String version,
  ) async => details;
  @override
  Future<AppUpgradeReview> loadAppUpgradeReview(
    InstalledApp app,
    AppVersionDetails details,
  ) async => review;
  @override
  Future<AppOperationResult> installApp(AppInstallRequest request) async {
    actions.add('install');
    created = request;
    return _verified;
  }

  @override
  Future<AppOperationResult> upgradeApp(AppUpgradeRequest request) async {
    actions.add('upgrade');
    upgraded = request;
    return _verified;
  }

  @override
  Future<AppOperationResult> uninstallApp(AppUninstallRequest request) async {
    actions.add('delete');
    deleted = request;
    return _verified;
  }

  @override
  Future<AppOperationResult> changeAppState(
    InstalledApp app,
    AppLifecycleAction action,
  ) async {
    actions.add(action.name);
    return _verified;
  }

  @override
  Future<AppOperationResult> pollAppJob(AppJob job) async {
    if (job.operation == 'catalog.sync') syncPolls++;
    return _verified;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _verified = AppOperationResult(outcome: AppOperationOutcome.verified);
