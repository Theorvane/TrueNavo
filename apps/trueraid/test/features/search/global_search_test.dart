import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/admin/admin_operation_page.dart';
import 'package:trueraid/features/admin/admin_schema_form.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/disks/disks_page.dart';
import 'package:trueraid/features/search/global_search.dart';
import 'package:trueraid/features/search/search_index.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _secret = 'synthetic-server-content-not-in-search';
const _input = Key('global-search-input');

class _FakeAdmin
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedSessionQueries {
  final calls = <String>[];
  @override
  final adminCatalog = AdminCatalog.fromMetadata(
    version: '25.10.1',
    metadata: {
      for (final method in ['disk.query', 'disk.update', 'pool.create'])
        method: {
          'job': false,
          'uploadable': false,
          'downloadable': false,
          'no_auth_required': false,
          'private': false,
          'description': _secret,
          'accepts': <Object?>[],
          'returns': {'type': 'object'},
        },
    },
  );
  @override
  Future<Object?> query(String method) async {
    calls.add(method);
    throw StateError('No transport');
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request.method.name);
    throw StateError('No transport');
  }

  @override
  Future<AdminResult> pollAdminJob(AdminJobSubmitted job) async {
    calls.add('core.get_jobs');
    throw StateError('No transport');
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
  }) async {
    calls.add('connect');
    throw StateError('No connector');
  }
}

class _Harness {
  final api = _FakeAdmin();
  late final ProviderContainer container;
  late GlobalKey<NavigatorState> navigatorKey;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  double width = 800,
  double scale = 1,
  double keyboard = 0,
  bool light = false,
  bool connected = true,
  bool shortcutsEnabled = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = _Harness();
  h.container = ProviderContainer(
    overrides: [
      dashboardActiveSessionProvider.overrideWith(
        (ref) => !connected
            ? null
            : AuthenticatedSession(
                profileId: 'sample',
                repository: h.api,
                availableMethodNames: h.api.adminCatalog.methods.keys.toSet(),
                version: '25.10.1',
                endpoint: 'wss://nas.example/api/current',
              ),
      ),
    ],
  );
  addTearDown(h.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: GlobalSearchHost(
        shortcutsEnabled: shortcutsEnabled,
        builder: (navigatorKey, observer) {
          h.navigatorKey = navigatorKey;
          return MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: [observer],
            theme: light ? TrueRAIDTheme.light() : TrueRAIDTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: child!,
            ),
            home: const Scaffold(
              appBar: _HomeBar(),
              body: Focus(autofocus: true, child: Text('Home fixture')),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

class _HomeBar extends StatelessWidget implements PreferredSizeWidget {
  const _HomeBar();
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) =>
      AppBar(title: const Text('Home'), actions: const [GlobalSearchButton()]);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-global-search')));
  await tester.pumpAndSettle();
  expect(find.byType(GlobalSearchDialog), findsOneWidget);
}

Future<void> _query(WidgetTester tester, String query) async {
  await tester.ensureVisible(find.byKey(_input));
  await tester.enterText(find.byKey(_input), query);
  await tester.pumpAndSettle();
}

Future<void> _shortcut(WidgetTester tester, {bool meta = false}) async {
  final modifier = meta
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Finder _result(NavigationSearchEntry entry) =>
    find.byKey(ValueKey('search-result-${entry.id}'));
bool _selected(WidgetTester tester, NavigationSearchEntry entry) =>
    tester.widget<Semantics>(_result(entry)).properties.selected == true;

void main() {
  for (final password in [false, true]) {
    testWidgets(
      'disabled shortcuts preserve inline ${password ? 'password' : 'OTP'} input',
      (tester) async {
        final h = await _pump(tester, shortcutsEnabled: false);
        final text = TextEditingController(text: _secret);
        addTearDown(text.dispose);
        h.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: TextField(
                key: const Key('inline-auth-input'),
                controller: text,
                autofocus: true,
                obscureText: password,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _shortcut(tester);
        await _shortcut(tester, meta: true);
        expect(find.byType(GlobalSearchDialog), findsNothing);
        expect(text.text, _secret);
        expect(find.byKey(const Key('inline-auth-input')), findsOneWidget);
        expect(h.api.calls, isEmpty);
      },
    );
  }
  testWidgets(
    'enabled shortcuts never cover a focused secret field on a pushed page',
    (tester) async {
      final h = await _pump(tester);
      h.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: TextField(
              key: Key('secret-input'),
              autofocus: true,
              obscureText: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _shortcut(tester);
      await _shortcut(tester, meta: true);
      expect(find.byType(GlobalSearchDialog), findsNothing);
      expect(find.byKey(const Key('secret-input')), findsOneWidget);
      expect(h.api.calls, isEmpty);
    },
  );
  testWidgets('background shortcut cannot create a new search popup', (
    tester,
  ) async {
    final h = await _pump(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    await _shortcut(tester);
    await _shortcut(tester, meta: true);
    expect(find.byType(GlobalSearchDialog), findsNothing);
    expect(h.api.calls, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await _shortcut(tester);
    expect(find.byType(GlobalSearchDialog), findsOneWidget);
  });
  testWidgets(
    'opening typing and closing searches only compiled navigation with zero RPC',
    (tester) async {
      final h = await _pump(tester);
      await _open(tester);
      await _query(tester, _secret);
      expect(find.text('No matching features.'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.button == true &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('search-result-'),
        ),
        findsNothing,
      );
      await _query(tester, '디스크');
      expect(_result(searchNavigation('디스크').first), findsOneWidget);
      expect(find.textContaining(_secret), findsNothing);
      await _key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(GlobalSearchDialog), findsNothing);
      expect(h.api.calls, isEmpty);
    },
  );
  testWidgets(
    'native disk operation opens guarded disk page instead of generic RPC form',
    (tester) async {
      final h = await _pump(tester);
      await _open(tester);
      await _query(tester, 'disk.query');
      final entry = searchNavigation('disk.query')
          .singleWhere((e) => e.operation?.method == 'disk.query');
      await tester.ensureVisible(_result(entry));
      await tester.tap(_result(entry));
      await tester.pumpAndSettle();
      expect(find.byType(DisksPage), findsOneWidget);
      expect(find.text('Disk management unavailable'), findsOneWidget);
      expect(find.byType(AdminOperationPage), findsNothing);
      expect(find.byType(AdminSchemaForm), findsNothing);
      expect(h.api.calls, isEmpty);
    },
  );
  testWidgets(
    'unsupported pool create is explanation-only despite advertised metadata',
    (tester) async {
      final h = await _pump(tester);
      await _open(tester);
      await _query(tester, 'pool.create');
      final entry = searchNavigation('pool.create')
          .singleWhere((e) => e.operation?.method == 'pool.create');
      expect(find.text('Unavailable · open explanation'), findsOneWidget);
      await tester.ensureVisible(_result(entry));
      await tester.tap(_result(entry));
      await tester.pumpAndSettle();
      expect(find.byType(AdminOperationPage), findsOneWidget);
      expect(find.text('This action is unavailable'), findsOneWidget);
      expect(find.byType(AdminSchemaForm), findsNothing);
      expect(find.byKey(const Key('admin-review-submit')), findsNothing);
      expect(h.api.calls, isEmpty);
    },
  );
  for (final meta in [false, true]) {
    testWidgets(
      '${meta ? 'Meta' : 'Ctrl'} K works on pushed pages and cannot stack dialogs',
      (tester) async {
        final h = await _pump(tester);
        h.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: Focus(autofocus: true, child: Text('Pushed page')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _shortcut(tester, meta: meta);
        expect(find.byType(GlobalSearchDialog), findsOneWidget);
        await _shortcut(tester, meta: meta);
        expect(find.byType(GlobalSearchDialog), findsOneWidget);
        await _key(tester, LogicalKeyboardKey.escape);
        expect(find.byType(GlobalSearchDialog), findsNothing);
        expect(find.text('Pushed page'), findsOneWidget);
        expect(h.api.calls, isEmpty);
      },
    );
  }
  testWidgets('direct repeated open calls are deduplicated by navigator', (
    tester,
  ) async {
    final h = await _pump(tester);
    final context = tester.element(find.byKey(const Key('open-global-search')));
    final first = showGlobalSearch(context), second = showGlobalSearch(context);
    await tester.pumpAndSettle();
    await second;
    expect(find.byType(GlobalSearchDialog), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);
    await first;
    expect(h.api.calls, isEmpty);
  });
  for (final auth in [false, true]) {
    testWidgets(
      '${auth ? 'authentication' : 'impact review'} popup stays above global shortcuts',
      (tester) async {
        final h = await _pump(tester);
        final context = tester.element(
          find.byKey(const Key('open-global-search')),
        );
        final dialog = showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(auth ? 'Authentication' : 'Impact review'),
            content: TextField(autofocus: true, obscureText: auth),
          ),
        );
        await tester.pumpAndSettle();
        await _shortcut(tester);
        await _shortcut(tester, meta: true);
        expect(find.byType(GlobalSearchDialog), findsNothing);
        expect(find.byType(AlertDialog), findsOneWidget);
        h.navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        await dialog;
        expect(h.api.calls, isEmpty);
      },
    );
  }
  testWidgets(
    'arrows wrap selection and reveal last result in the scroll viewport',
    (tester) async {
      final h = await _pump(tester, width: 320, scale: 2, keyboard: 300);
      await _open(tester);
      final entries = searchNavigation('');
      expect(_selected(tester, entries.first), isTrue);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_selected(tester, entries.last), isTrue);
      expect(_result(entries.last).hitTestable(), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_selected(tester, entries.first), isTrue);
      expect(_result(entries.first).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(h.api.calls, isEmpty);
    },
  );
  testWidgets('Enter/search action opens the keyboard-selected native result', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _open(tester);
    await _query(tester, 'disk.query');
    final entries = searchNavigation('disk.query');
    expect(entries.length, greaterThan(1));
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_selected(tester, entries[1]), isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byType(DisksPage), findsOneWidget);
    expect(find.byType(GlobalSearchDialog), findsNothing);
    expect(h.api.calls, isEmpty);
  });
  testWidgets(
    'no results ignores arrows and submission but Escape still closes',
    (tester) async {
      final h = await _pump(tester);
      await _open(tester);
      await _query(tester, 'not-a-feature-12345');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowUp);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byType(GlobalSearchDialog), findsOneWidget);
      expect(find.text('No matching features.'), findsOneWidget);
      await tester.tap(find.byKey(_input));
      await _key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(GlobalSearchDialog), findsNothing);
      expect(h.api.calls, isEmpty);
    },
  );
  testWidgets(
    'closing and reopening discards search text and previous selection',
    (tester) async {
      final h = await _pump(tester);
      await _open(tester);
      await _query(tester, 'disk.query');
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await tester.ensureVisible(find.byTooltip('Close search'));
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      await _open(tester);
      expect(
        tester.widget<TextField>(find.byKey(_input)).controller!.text,
        isEmpty,
      );
      expect(_selected(tester, searchNavigation('').first), isTrue);
      expect(h.api.calls, isEmpty);
    },
  );
  testWidgets('background removes popup and drops query without navigation', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _open(tester);
    await _query(tester, _secret);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.byType(GlobalSearchDialog), findsNothing);
    expect(find.text('Home fixture'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await _open(tester);
    expect(
      tester.widget<TextField>(find.byKey(_input)).controller!.text,
      isEmpty,
    );
    expect(find.textContaining(_secret), findsNothing);
    expect(h.api.calls, isEmpty);
  });
  testWidgets('disconnected search still offers local navigation without RPC', (
    tester,
  ) async {
    final h = await _pump(tester, connected: false);
    await _open(tester);
    await _query(tester, 'Disks');
    expect(_result(searchNavigation('Disks').first), findsOneWidget);
    expect(h.api.calls, isEmpty);
  });
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final light in [false, true]) {
      testWidgets(
        'search fits $width light=$light 200percent with 300px keyboard',
        (tester) async {
          final h = await _pump(
            tester,
            width: width,
            light: light,
            scale: 2,
            keyboard: 300,
          );
          await _open(tester);
          await _query(tester, 'pool.create');
          final entry = searchNavigation('pool.create').first;
          await tester.ensureVisible(_result(entry));
          await tester.pumpAndSettle();
          expect(_result(entry).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(h.api.calls, isEmpty);
        },
      );
    }
  }
}
