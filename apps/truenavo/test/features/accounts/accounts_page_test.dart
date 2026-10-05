import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/accounts/accounts_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'accounts_fakes.dart';

Future<AccountsHarness> pump(
  WidgetTester tester, {
  double scale = 1,
  Set<String> methods = accountMethods,
  bool demoHasKey = true,
}) async {
  final h = AccountsHarness(methods: methods, demoHasKey: demoHasKey);
  addTearDown(h.dispose);
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
        home: const AccountsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> openDemo(WidgetTester tester) =>
    tap(tester, find.byKey(const Key('account-user-2')));

void main() {
  testWidgets('inventory and privilege mapping render without mutations', (
    tester,
  ) async {
    final h = await pump(tester);
    expect(h.api.reads, 1);
    expect(find.text('demo'), findsOneWidget);
    await tap(tester, find.byKey(const Key('accounts-tab-2')));
    expect(find.text('Local Administrator'), findsOneWidget);
    expect(find.textContaining('GID 3001'), findsOneWidget);
    expect(h.api.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('create and edit permissions are independently gated', (
    tester,
  ) async {
    await pump(
      tester,
      methods: accountMethods.difference({'user.create', 'user.update'}),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('accounts-create-0')))
          .onPressed,
      isNull,
    );
    await openDemo(tester);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('account-review-user')))
          .onPressed,
      isNull,
    );
  });
  testWidgets('protected user is read-only and cannot be deleted', (
    tester,
  ) async {
    final h = await pump(tester);
    await tap(tester, find.byKey(const Key('account-user-3')));
    expect(find.textContaining('This identity is protected'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('account-review-user')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('account-delete-user')))
          .onPressed,
      isNull,
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'metadata permission is explained and gates unsafe home operations',
    (tester) async {
      await pump(
        tester,
        methods: accountMethods.difference({'filesystem.stat'}),
      );
      await openDemo(tester);
      expect(
        find.textContaining('Filesystem metadata read permission'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('account-review-user')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('account-delete-user')),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'first-key creation is visibly unavailable without a verified existing key',
    (tester) async {
      final h = await pump(tester, demoHasKey: false);
      await openDemo(tester);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('account-replace-ssh')),
            )
            .onChanged,
        isNull,
      );
      expect(
        find.textContaining('first-key creation is not supported'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('account-new-ssh-key')), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'SSH replacement review explains recursive permissions without showing key material',
    (tester) async {
      final h = await pump(tester);
      await openDemo(tester);
      await tap(tester, find.byKey(const Key('account-replace-ssh')));
      const key =
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB fixture';
      await tester.enterText(find.byKey(const Key('account-new-ssh-key')), key);
      await tap(tester, find.byKey(const Key('account-review-user')));
      expect(find.textContaining('recursively removes ACLs'), findsOneWidget);
      expect(
        find.textContaining('existing verified regular authorized_keys'),
        findsOneWidget,
      );
      expect(find.textContaining('/mnt/tank/demo/.ssh'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AlertDialog), matching: find.text(key)),
        findsNothing,
      );
      await tap(tester, find.byKey(const Key('account-confirm-cancel')));
      expect(find.byKey(const Key('account-new-ssh-key')), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'profile change uses exact confirmation and leaves private inputs out',
    (tester) async {
      final h = await pump(tester);
      await openDemo(tester);
      await tester.enterText(
        find.byKey(const Key('account-full-name')),
        'Reviewed full name',
      );
      await tap(tester, find.byKey(const Key('account-review-user')));
      expect(find.text('Full name: Reviewed full name'), findsOneWidget);
      expect(h.api.writes, isEmpty);
      await tester.enterText(
        find.byKey(const Key('account-confirm-name')),
        'DEMO',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('account-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('account-confirm-name')),
        'demo',
      );
      await tester.pump();
      await tap(tester, find.byKey(const Key('account-confirm-submit')));
      expect(h.api.writes, ['user.update']);
      final request = h.api.lastRequest! as AccountUserUpdate;
      expect(request.fullName, 'Reviewed full name');
      expect(request.password, isNull);
      expect(request.sshPublicKey, isNull);
      expect(request.groupIds, isNull);
    },
  );
  testWidgets('cancelled password review clears the secret and sends nothing', (
    tester,
  ) async {
    final h = await pump(tester);
    await openDemo(tester);
    await tester.enterText(
      find.byKey(const Key('account-new-password')),
      'private-fixture-password',
    );
    await tap(tester, find.byKey(const Key('account-review-user')));
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('private-fixture-password'),
      ),
      findsNothing,
    );
    expect(find.textContaining('new private value supplied'), findsOneWidget);
    await tap(tester, find.byKey(const Key('account-confirm-cancel')));
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('account-new-password')))
          .controller!
          .text,
      isEmpty,
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets('connection change hides pending account review immediately', (
    tester,
  ) async {
    final h = await pump(tester);
    await openDemo(tester);
    await tester.enterText(
      find.byKey(const Key('account-full-name')),
      'Private person name',
    );
    await tap(tester, find.byKey(const Key('account-review-user')));
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    await tester.pumpAndSettle();
    expect(find.text('Review expired'), findsOneWidget);
    expect(find.text('Full name: Private person name'), findsNothing);
    expect(find.byKey(const Key('account-confirm-submit')), findsNothing);
    expect(h.api.writes, isEmpty);
    await tap(tester, find.text('Close'));
    expect(find.textContaining('This account review expired'), findsOneWidget);
  });
  testWidgets(
    'group membership review names the granted roles and selected user',
    (tester) async {
      final h = await pump(tester);
      await tap(tester, find.byKey(const Key('accounts-tab-1')));
      await tap(tester, find.byKey(const Key('account-group-20')));
      await tap(tester, find.byKey(const Key('account-group-member-2')));
      await tap(tester, find.byKey(const Key('account-review-group')));
      expect(find.text('Members: demo'), findsOneWidget);
      expect(
        find.text('Roles granted by membership: READONLY_ADMIN'),
        findsOneWidget,
      );
      await tap(tester, find.byKey(const Key('account-confirm-cancel')));
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'delete review names exact SSH directory and preserves group and home files',
    (tester) async {
      final h = await pump(tester);
      await openDemo(tester);
      await tap(tester, find.byKey(const Key('account-delete-user')));
      expect(find.textContaining('/mnt/tank/demo/.ssh'), findsOneWidget);
      expect(find.textContaining('Keeps the primary group'), findsOneWidget);
      await tap(tester, find.byKey(const Key('account-confirm-cancel')));
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    '320px at 200 percent supports user editor and confirmation without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = await pump(tester, scale: 2);
      await openDemo(tester);
      await tester.enterText(
        find.byKey(const Key('account-full-name')),
        'Compact reviewed name',
      );
      await tap(tester, find.byKey(const Key('account-review-user')));
      await tester.ensureVisible(find.byKey(const Key('account-confirm-name')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tap(tester, find.byKey(const Key('account-confirm-cancel')));
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    '320px at 200 percent supports group creation and membership review',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = await pump(tester, scale: 2);
      await tap(tester, find.byKey(const Key('accounts-tab-1')));
      await tap(tester, find.byKey(const Key('accounts-create-1')));
      await tester.enterText(
        find.byKey(const Key('account-group-name')),
        'compact-group',
      );
      await tap(tester, find.byKey(const Key('account-group-member-2')));
      await tap(tester, find.byKey(const Key('account-review-group')));
      expect(find.text('Members: demo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester, find.byKey(const Key('account-confirm-cancel')));
      expect(h.api.writes, isEmpty);
    },
  );
}
