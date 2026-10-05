import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/directory_idmap/directory_idmap_page.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  testWidgets('ID mapping chart labels ranges on a shared axis', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DirectoryIdmapRangeChart(
            domains: [
              DirectoryIdmapDomain(
                label: 'BUILTIN',
                backend: 'TDB',
                range: DirectoryIdmapRange(low: 90000001, high: 100000000),
              ),
              DirectoryIdmapDomain(
                label: 'Primary domain',
                backend: 'RID',
                range: DirectoryIdmapRange(low: 100000001, high: 200000000),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('UID/GID range map'), findsOneWidget);
    expect(find.text('90000001 – 200000000'), findsOneWidget);
    expect(find.text('BUILTIN · 90000001–100000000'), findsOneWidget);
    expect(find.text('Primary domain · 100000001–200000000'), findsOneWidget);
  });
  testWidgets('bounded RID editor requires a changed valid range', (
    tester,
  ) async {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      serviceType: 'ACTIVEDIRECTORY',
      enabled: false,
      status: null,
      builtin: const DirectoryIdmapDomain(
        label: 'BUILTIN',
        backend: 'TDB',
        range: DirectoryIdmapRange(low: 90000001, high: 100000000),
      ),
      primary: const DirectoryIdmapDomain(
        label: 'Primary domain',
        backend: 'RID',
        range: DirectoryIdmapRange(low: 100000001, high: 200000000),
      ),
      trusted: const [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [DirectoryIdmapEditor(inventory: inventory)],
            ),
          ),
        ),
      ),
    );
    expect(
      find.text('Change at least one range or backend option.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).at(2), '110000001');
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review ID mapping change'),
    );
    expect(button.onPressed, isNotNull);
    expect(find.text('Submit ID mapping update once'), findsNothing);
  });
  testWidgets('existing trusted domain range is editable', (tester) async {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      serviceType: 'ACTIVEDIRECTORY',
      enabled: false,
      status: null,
      builtin: const DirectoryIdmapDomain(
        label: 'BUILTIN',
        backend: 'TDB',
        range: DirectoryIdmapRange(low: 90000001, high: 100000000),
      ),
      primary: const DirectoryIdmapDomain(
        label: 'Primary domain',
        backend: 'RID',
        range: DirectoryIdmapRange(low: 100000001, high: 200000000),
      ),
      trusted: const [
        DirectoryIdmapDomain(
          label: 'TRUST_A',
          backend: 'RID',
          range: DirectoryIdmapRange(low: 200000001, high: 300000000),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [DirectoryIdmapEditor(inventory: inventory)],
            ),
          ),
        ),
      ),
    );
    expect(find.widgetWithText(TextField, 'TRUST_A low'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'TRUST_A high'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(4), '210000001');
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review ID mapping change'),
    );
    expect(button.onPressed, isNotNull);
  });
  testWidgets('RID option-only change enables ID mapping review', (
    tester,
  ) async {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      serviceType: 'ACTIVEDIRECTORY',
      enabled: false,
      status: null,
      builtin: const DirectoryIdmapDomain(
        label: 'BUILTIN',
        backend: 'TDB',
        range: DirectoryIdmapRange(low: 90000001, high: 100000000),
      ),
      primary: const DirectoryIdmapDomain(
        label: 'Primary domain',
        backend: 'RID',
        range: DirectoryIdmapRange(low: 100000001, high: 200000000),
        options: DirectoryIdmapBackendOptions.rid(sssdCompat: false),
      ),
      trusted: const [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [DirectoryIdmapEditor(inventory: inventory)],
            ),
          ),
        ),
      ),
    );
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Primary domain SSSD compatibility',
    );
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review ID mapping change'),
    );
    expect(button.onPressed, isNotNull);
  });
  testWidgets('new RID trusted domain requires valid nonoverlapping range', (
    tester,
  ) async {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      serviceType: 'ACTIVEDIRECTORY',
      enabled: false,
      status: null,
      builtin: const DirectoryIdmapDomain(
        label: 'BUILTIN',
        backend: 'TDB',
        range: DirectoryIdmapRange(low: 90000001, high: 100000000),
      ),
      primary: const DirectoryIdmapDomain(
        label: 'Primary domain',
        backend: 'RID',
        range: DirectoryIdmapRange(low: 100000001, high: 200000000),
      ),
      trusted: const [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [DirectoryIdmapEditor(inventory: inventory)],
            ),
          ),
        ),
      ),
    );
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Add one trusted domain',
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, 'New trusted domain NetBIOS name'),
      'TRUST_NEW',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'New trusted domain low'),
      '190000000',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'New trusted domain high'),
      '300000000',
    );
    await tester.pump();
    expect(find.textContaining('must not overlap'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'New trusted domain low'),
      '200000001',
    );
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review ID mapping change'),
    );
    expect(button.onPressed, isNotNull);
  });
  testWidgets('trusted-domain removal is a separate reviewed choice', (
    tester,
  ) async {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      serviceType: 'ACTIVEDIRECTORY',
      enabled: false,
      status: null,
      builtin: const DirectoryIdmapDomain(
        label: 'BUILTIN',
        backend: 'TDB',
        range: DirectoryIdmapRange(low: 90000001, high: 100000000),
      ),
      primary: const DirectoryIdmapDomain(
        label: 'Primary domain',
        backend: 'RID',
        range: DirectoryIdmapRange(low: 100000001, high: 200000000),
      ),
      trusted: const [
        DirectoryIdmapDomain(
          label: 'TRUST_A',
          backend: 'RID',
          range: DirectoryIdmapRange(low: 200000001, high: 300000000),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [DirectoryIdmapEditor(inventory: inventory)],
            ),
          ),
        ),
      ),
    );
    final selector = find.byType(DropdownButtonFormField<String>);
    expect(selector, findsOneWidget);
    await tester.ensureVisible(selector);
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pumpAndSettle();
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('TRUST_A').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Removing TRUST_A'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'Primary domain low'),
          )
          .enabled,
      isFalse,
    );
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review ID mapping change'),
    );
    expect(review.onPressed, isNotNull);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Add one trusted domain'),
          )
          .onChanged,
      isNull,
    );
  });
  testWidgets('primary backend migration is isolated in the editor', (
    tester,
  ) async {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      serviceType: 'ACTIVEDIRECTORY',
      enabled: false,
      status: null,
      builtin: const DirectoryIdmapDomain(
        label: 'BUILTIN',
        backend: 'TDB',
        range: DirectoryIdmapRange(low: 90000001, high: 100000000),
      ),
      primary: const DirectoryIdmapDomain(
        label: 'Primary domain',
        backend: 'RID',
        range: DirectoryIdmapRange(low: 100000001, high: 200000000),
        options: DirectoryIdmapBackendOptions.rid(sssdCompat: false),
      ),
      trusted: const [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [DirectoryIdmapEditor(inventory: inventory)],
            ),
          ),
        ),
      ),
    );
    final selector = find.byKey(const ValueKey('migrate:'));
    await tester.ensureVisible(selector);
    await tester.pumpAndSettle();
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Primary domain').last);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Changing the backend may remap'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextField, 'Primary domain low'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'Primary domain low'),
          )
          .enabled,
      isFalse,
    );
    expect(find.text('Migrated domain schema mode'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review ID mapping change'),
          )
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'cache refresh panel explains scope and requires healthy service',
    (tester) async {
      final inventory = DirectoryIdmapInventory(
        endpoint: 'wss://nas.example.invalid/api/current',
        hostId:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        serviceType: 'LDAP',
        enabled: true,
        status: 'FAULTED',
        builtin: null,
        primary: null,
        trusted: const [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
          child: MaterialApp(
            home: Scaffold(
              body: DirectoryMaintenancePanel(inventory: inventory),
            ),
          ),
        ),
      );
      expect(
        find.textContaining('does not repair share authentication'),
        findsOneWidget,
      );
      expect(find.textContaining('Available only while'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review cache refresh'),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('AD-only keytab sync is separately offered', (tester) async {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      serviceType: 'ACTIVEDIRECTORY',
      enabled: true,
      status: 'HEALTHY',
      builtin: null,
      primary: null,
      trusted: const [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: DirectoryMaintenancePanel(
              inventory: inventory,
              canRefreshCache: false,
              canSyncKeytab: true,
            ),
          ),
        ),
      ),
    );
    expect(
      find.textContaining('updated Kerberos service principal names'),
      findsOneWidget,
    );
    expect(find.text('Review cache refresh'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review AD keytab sync'),
          )
          .onPressed,
      isNotNull,
    );
  });
}
