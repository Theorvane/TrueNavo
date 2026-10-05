import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/apps/app_config_page.dart';
import 'package:truenavo/features/apps/apps_controller.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  testWidgets(
    'opening settings reads a safe review without selecting or writing defaults',
    (tester) async {
      final h = await _pump(tester);
      expect(h.api.reads, 1);
      expect(h.api.writes, isEmpty);
      expect(find.text('Current · "Existing title"'), findsOneWidget);
      expect(find.textContaining('server-secret-value'), findsNothing);
      expect(find.textContaining('nested-secret-value'), findsNothing);
      expect(find.textContaining('Installer default'), findsNothing);
      expect(_reviewButton(tester).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'only explicitly selected changed leaf is reviewed and dispatched',
    (tester) async {
      final h = await _pump(tester);
      await _editTitle(tester, 'New title');
      await _tap(tester, find.byKey(const Key('app-config-review')));
      expect(
        find.text('settings › title\n"Existing title" → "New title"'),
        findsOneWidget,
      );
      expect(h.api.writes, isEmpty);
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
      expect(h.api.writes, hasLength(1));
      final patch = h.api.writes.single.patches.single;
      expect(patch.fieldId, '/settings/title');
      expect(patch.value, 'New title');
      expect(find.text('This review has been used'), findsOneWidget);
      expect(find.byKey(const Key('app-config-review')), findsNothing);
    },
  );
  testWidgets('cancel and deselect never submit replacement defaults', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _editTitle(tester, 'Cancelled title');
    await _tap(tester, find.byKey(const Key('app-config-review')));
    await _tap(tester, find.text('Cancel'));
    expect(h.api.writes, isEmpty);
    await _tap(
      tester,
      find.byKey(const ValueKey('app-config-select-/settings/title')),
    );
    expect(_reviewButton(tester).onPressed, isNull);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('read-only account cannot select changes', (tester) async {
    final h = await _pump(tester, writable: false);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('app-config-select-/settings/title')),
          )
          .onChanged,
      isNull,
    );
    expect(_reviewButton(tester).onPressed, isNull);
    expect(h.api.writes, isEmpty);
    expect(find.textContaining('Settings are view-only.'), findsOneWidget);
  });
  testWidgets(
    'protected secrets, paths, immutable values and lists stay locked',
    (tester) async {
      await _pump(tester);
      for (final id in [
        '/secret',
        '/settings/password',
        '/path',
        '/immutable_id',
        '/items',
      ]) {
        expect(find.byKey(ValueKey('app-config-select-$id')), findsNothing);
      }
      expect(find.text('Current · [protected value]'), findsWidgets);
      expect(find.textContaining('server-secret-value'), findsNothing);
      expect(find.textContaining('nested-secret-value'), findsNothing);
    },
  );
  testWidgets('active effectful normalization blocks the entire review', (
    tester,
  ) async {
    final h = await _pump(tester, unsafe: true);
    expect(find.text('Configuration changes unavailable'), findsOneWidget);
    expect(_reviewButton(tester).onPressed, isNull);
    for (final field in tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    )) {
      expect(field.onChanged, isNull);
    }
    expect(h.api.writes, isEmpty);
  });
  testWidgets('search does not discard selected field values', (tester) async {
    final h = await _pump(tester);
    await _editTitle(tester, 'Kept across filter');
    await _reveal(tester, find.byKey(const Key('app-config-search')));
    await tester.enterText(find.byKey(const Key('app-config-search')), 'port');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('app-config-select-/settings/title')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('admin-value-new_value')),
          )
          .controller!
          .text,
      'Kept across filter',
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'session replacement hides old configuration and cancels confirmation',
    (tester) async {
      final h = await _pump(tester);
      await _editTitle(tester, 'Not sent');
      await _tap(tester, find.byKey(const Key('app-config-review')));
      h.select(null);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-confirm-submit')), findsNothing);
      expect(find.textContaining('Not sent'), findsNothing);
      expect(find.textContaining('Existing title'), findsNothing);
      await _tap(tester, find.text('Close review'));
      expect(h.api.writes, isEmpty);
      expect(find.text('Connection changed'), findsOneWidget);
      expect(find.textContaining('Existing title'), findsNothing);
    },
  );
  testWidgets('shared lock prevents even a reviewed fake update', (
    tester,
  ) async {
    final h = await _pump(tester);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire()!;
    await _editTitle(tester, 'Blocked title');
    await _tap(tester, find.byKey(const Key('app-config-review')));
    await tester.enterText(find.byKey(const Key('app-confirm-name')), 'media');
    await _tap(tester, find.byKey(const Key('app-confirm-submit')));
    expect(h.api.writes, isEmpty);
    expect(lock.acquire(), isNull);
    lock.release(owner);
  });
  testWidgets(
    'pending configuration job keeps editing locked and tracks only its handle',
    (tester) async {
      final h = await _pump(tester);
      h.api.result = const AppOperationResult(
        outcome: AppOperationOutcome.submitted,
        job: _job,
      );
      await _editTitle(tester, 'Pending title');
      await _tap(tester, find.byKey(const Key('app-config-review')));
      await tester.enterText(
        find.byKey(const Key('app-confirm-name')),
        'media',
      );
      // A running progress indicator intentionally never settles.
      await tester.pump();
      await tester.tap(find.byKey(const Key('app-confirm-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(h.api.writes, hasLength(1));
      expect(h.container.read(appsControllerProvider).pending, isTrue);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      await h.container.read(appsControllerProvider.notifier).checkJob();
      await tester.pumpAndSettle();
      expect(h.api.polls, [_job]);
      expect(h.api.writes, hasLength(1));
    },
  );
  testWidgets(
    'compact 320px 200 percent editor and exact review do not overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = await _pump(tester, scale: 2);
      await _editTitle(tester, 'Compact title');
      await _tap(tester, find.byKey(const Key('app-config-review')));
      await _reveal(tester, find.byKey(const Key('app-confirm-name')));
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('Cancel'));
      expect(h.api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

FilledButton _reviewButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('app-config-review')));
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 100,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _editTitle(WidgetTester tester, String value) async {
  await _tap(
    tester,
    find.byKey(const ValueKey('app-config-select-/settings/title')),
  );
  final input = find.byKey(const ValueKey('admin-value-new_value'));
  await _reveal(tester, input);
  expect(tester.widget<TextField>(input).controller!.text, 'Existing title');
  await tester.enterText(input, value);
  await tester.pumpAndSettle();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool writable = true,
  bool unsafe = false,
  double scale = 1,
}) async {
  final h = _Harness(writable: writable, unsafe: unsafe);
  addTearDown(h.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: AppConfigPage(session: h.session, app: _app),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

class _Harness {
  _Harness({required bool writable, required bool unsafe})
    : api = _FakeConfig(unsafe: unsafe) {
    session = AuthenticatedSession(
      profileId: 'sample',
      repository: api,
      availableMethodNames: {'app.config', if (writable) 'app.update'},
      version: '25.10.1',
      endpoint: 'wss://sample.example/api/current',
    );
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final _FakeConfig api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  void select(AuthenticatedSession? value) {
    active = value;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }
}

class _FakeConfig implements SessionRepository, AuthenticatedAppsSession {
  _FakeConfig({required this.unsafe});
  final bool unsafe;
  var reads = 0;
  final writes = <AppConfigUpdateRequest>[];
  final polls = <AppJob>[];
  AppOperationResult result = const AppOperationResult(
    outcome: AppOperationOutcome.verified,
  );
  late final review = AppConfigReview(
    app: _app,
    schema: AppConfigSchema.fromVersionDetails(
      {
        'schema': {
          'questions': [
            {
              'variable': 'settings',
              'schema': {
                'type': 'dict',
                'attrs': [
                  {
                    'variable': 'title',
                    'label': 'Library title',
                    'schema': {
                      'type': 'string',
                      'default': 'Installer default',
                      'max_length': 80,
                    },
                  },
                  {
                    'variable': 'enabled',
                    'schema': {'type': 'boolean'},
                  },
                  {
                    'variable': 'port',
                    'schema': {
                      'type': 'int',
                      'min': 1,
                      'max': 65535,
                      r'$ref': ['definitions/port'],
                    },
                  },
                  {
                    'variable': 'password',
                    'schema': {'type': 'string', 'private': true},
                  },
                ],
              },
            },
            {
              'variable': 'secret',
              'schema': {'type': 'string', 'private': true},
            },
            {
              'variable': 'path',
              'schema': {'type': 'hostpath'},
            },
            {
              'variable': 'immutable_id',
              'schema': {'type': 'string', 'immutable': true},
            },
            {
              'variable': 'items',
              'schema': {
                'type': 'list',
                'items': [
                  {
                    'variable': 'item',
                    'schema': {'type': 'string'},
                  },
                ],
              },
            },
            if (unsafe)
              {
                'variable': 'acl',
                'schema': {
                  'type': 'dict',
                  r'$ref': ['normalize/acl'],
                  'attrs': [],
                },
              },
          ],
        },
      },
      currentValues: {
        'settings': {
          'title': 'Existing title',
          'enabled': true,
          'port': 30000,
          'password': 'nested-secret-value',
        },
        'secret': 'server-secret-value',
        'path': '/mnt/tank/config',
        'immutable_id': 'original',
        'items': ['one'],
        if (unsafe)
          'acl': <String, Object?>{
            'path': '/mnt/tank/data',
            'entries': [
              {'id': 1000, 'id_type': 'USER', 'access': 'READ'},
            ],
          },
      },
    ),
    warnings: const [],
  );
  @override
  Future<AppConfigReview> loadAppConfigReview(InstalledApp app) async {
    reads++;
    return review;
  }

  @override
  Future<AppOperationResult> updateApp(AppConfigUpdateRequest request) async {
    writes.add(request);
    return result;
  }

  @override
  Future<AppOperationResult> pollAppJob(AppJob job) async {
    polls.add(job);
    return const AppOperationResult(
      outcome: AppOperationOutcome.verified,
      job: _job,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _app = InstalledApp(
  id: 'media',
  name: 'media',
  state: 'RUNNING',
  version: '1.0.0',
  catalogApp: 'media',
  train: 'stable',
  customApp: false,
);
const _job = AppJob(id: 31, appName: 'media', operation: 'app.update');
