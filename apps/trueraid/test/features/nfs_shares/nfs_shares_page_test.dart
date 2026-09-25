import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/nfs_shares_preview.dart';
import 'package:trueraid/features/nfs_shares/nfs_shares_controller.dart';
import 'package:trueraid/features/nfs_shares/nfs_shares_page.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'nfs_shares_fakes.dart';

Future<NfsHarness> pumpNfs(
  WidgetTester tester, {
  NfsFake? fake,
  bool editor = false,
  bool create = false,
  double width = 800,
  double scale = 1,
  bool light = false,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = NfsHarness(fake: fake);
  addTearDown(h.dispose);
  await h.container.read(nfsSharesInventoryProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: light ? TrueRAIDTheme.light() : TrueRAIDTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: editor
            ? NfsShareEditor(
                session: h.session,
                inventory: h.api.inventory,
                share: create ? null : h.api.inventory.shares.first,
              )
            : const NfsSharesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await reveal(tester, f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String key, String value) async {
  final f = find.byKey(Key(key));
  await reveal(tester, f);
  await tester.enterText(f, value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'inventory includes real service state and honest disjoint enablement counts',
    (tester) async {
      final h = await pumpNfs(tester);
      expect(find.text('Enabled · 1'), findsOneWidget);
      expect(find.text('Disabled · 1'), findsOneWidget);
      final theme = tester.element(find.byType(NfsSharesPage)).tdTheme;
      expect(
        (tester
                    .widget<DecoratedBox>(
                      find.byKey(const Key('nfs-enabled-dot')),
                    )
                    .decoration
                as BoxDecoration)
            .color,
        theme.statusSuccess,
      );
      expect(
        (tester
                    .widget<DecoratedBox>(
                      find.byKey(const Key('nfs-disabled-dot')),
                    )
                    .decoration
                as BoxDecoration)
            .color,
        theme.textMuted,
      );
      expect(find.text('NFS RUNNING'), findsOneWidget);
      expect(find.textContaining('not connected clients'), findsOneWidget);
      expect(h.api.writes, isEmpty);
      expect(h.api.reviews, isEmpty);
    },
  );
  testWidgets(
    'read-only account and blocked inventory visibly disable all mutations',
    (tester) async {
      final h = await pumpNfs(tester, fake: NfsFake(writable: false));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('nfs-create')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('nfs-edit-4')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('nfs-delete-4')))
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'delete requires exact target plus global reload acknowledgement',
    (tester) async {
      final h = await pumpNfs(tester);
      await tapKey(tester, 'nfs-delete-4');
      expect(h.api.reviews.single.action, NfsShareAction.delete);
      expect(h.api.writes, isEmpty);
      expect(find.textContaining('not the dataset or files'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('nfs-confirm')))
            .onPressed,
        isNull,
      );
      await enter(tester, 'nfs-confirmation', 'wrong');
      await tapKey(tester, 'nfs-impact-ack');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('nfs-confirm')))
            .onPressed,
        isNull,
      );
      await enter(tester, 'nfs-confirmation', 'NFS #4: /mnt/tank/media');
      await tapKey(tester, 'nfs-confirm');
      expect(h.api.writes, hasLength(1));
      expect(find.text('Configuration read back'), findsOneWidget);
    },
  );
  testWidgets(
    'edit round-trips settings and needs reviewed confirmation before write',
    (tester) async {
      final h = await pumpNfs(tester, editor: true);
      await enter(tester, 'nfs-comment', 'New comment');
      await tapKey(tester, 'nfs-review');
      expect(h.api.reviews, hasLength(1));
      expect(h.api.reviews.single.settings!.networks, ['192.168.10.0/24']);
      expect(h.api.reviews.single.settings!.comment, 'New comment');
      expect(h.api.writes, isEmpty);
      expect(find.text('Before'), findsOneWidget);
      expect(find.text('After'), findsOneWidget);
      await enter(tester, 'nfs-confirmation', 'NFS #4: /mnt/tank/media');
      await tapKey(tester, 'nfs-impact-ack');
      await tapKey(tester, 'nfs-confirm');
      expect(h.api.writes, hasLength(1));
    },
  );
  testWidgets(
    'create chooses an existing dataset, never free-form path or ACL reset',
    (tester) async {
      final h = await pumpNfs(tester, editor: true, create: true);
      await tapKey(tester, 'nfs-dataset');
      await tester.tap(find.text('tank/new').last);
      await tester.pumpAndSettle();
      await tapKey(tester, 'nfs-review');
      expect(h.api.reviews.single.action, NfsShareAction.create);
      expect(h.api.reviews.single.settings!.path, '/mnt/tank/new');
      expect(find.textContaining('Both client lists'), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('invalid host and canonical network fail before review', (
    tester,
  ) async {
    final h = await pumpNfs(tester, editor: true);
    await enter(tester, 'nfs-hosts', 'nas.example');
    await tapKey(tester, 'nfs-review');
    expect(h.api.reviews, isEmpty);
    expect(find.byKey(const Key('nfs-editor-error')), findsOneWidget);
    await enter(tester, 'nfs-hosts', '');
    await enter(tester, 'nfs-networks', '192.168.10.1/24');
    await tapKey(tester, 'nfs-review');
    expect(h.api.reviews, isEmpty);
  });
  testWidgets('local mapping inputs are typed native controls and reviewed', (
    tester,
  ) async {
    final h = await pumpNfs(tester, editor: true);
    await tapKey(tester, 'nfs-mapping');
    await tester.tap(find.text('Map every client user').last);
    await tester.pumpAndSettle();
    await enter(tester, 'nfs-map-user', 'backup');
    await enter(tester, 'nfs-map-group', 'backup');
    await tapKey(tester, 'nfs-review');
    expect(h.api.reviews.single.settings!.mapallUser, 'backup');
    expect(h.api.reviews.single.settings!.mapallGroup, 'backup');
    expect(h.api.writes, isEmpty);
  });
  testWidgets('session switch immediately hides editor fields', (tester) async {
    final h = await pumpNfs(tester, editor: true);
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nfs-comment')), findsNothing);
    expect(
      find.textContaining('Previous server and export details are hidden'),
      findsOneWidget,
    );
    expect(find.text('/mnt/tank/media'), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('session switch during modal hides review and disables confirm', (
    tester,
  ) async {
    final h = await pumpNfs(tester);
    await tapKey(tester, 'nfs-delete-4');
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    await tester.pumpAndSettle();
    expect(find.text('Review is no longer current'), findsOneWidget);
    expect(find.byKey(const Key('nfs-confirmation')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('nfs-confirm')))
          .onPressed,
      isNull,
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'session switch during asynchronous review discards stale response',
    (tester) async {
      final p = Completer<NfsShareReview>();
      final fake = NfsFake()..onReview = (_) => p.future;
      final h = await pumpNfs(tester, fake: fake);
      await reveal(tester, find.byKey(const Key('nfs-delete-4')));
      await tester.tap(find.byKey(const Key('nfs-delete-4')));
      await tester.pump();
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      p.complete(nfsReview());
      await tester.pumpAndSettle();
      expect(find.byType(NfsShareReviewDialog), findsNothing);
      expect(fake.writes, isEmpty);
    },
  );
  testWidgets(
    'draft stays expired after disconnect and exact same session and inventory return',
    (tester) async {
      final h = await pumpNfs(tester, editor: true);
      await enter(tester, 'nfs-comment', 'Prior private draft');
      h.select(null);
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(
        identical(
          h.container.read(nfsSharesInventoryProvider).asData?.value,
          h.api.inventory,
        ),
        isTrue,
      );
      expect(find.text('Editor is no longer current'), findsOneWidget);
      expect(find.byKey(const Key('nfs-comment')), findsNothing);
      expect(find.text('Prior private draft'), findsNothing);
      expect(find.byKey(const Key('nfs-review')), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'draft stays expired after reloading the exact same inventory object',
    (tester) async {
      final h = await pumpNfs(tester, editor: true);
      h.container.invalidate(nfsSharesInventoryProvider);
      await h.container.read(nfsSharesInventoryProvider.future);
      await tester.pumpAndSettle();
      expect(
        identical(
          h.container.read(nfsSharesInventoryProvider).asData?.value,
          h.api.inventory,
        ),
        isTrue,
      );
      expect(find.text('Editor is no longer current'), findsOneWidget);
      expect(find.byKey(const Key('nfs-comment')), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'typed review can never revive after same-object connection restoration',
    (tester) async {
      final h = await pumpNfs(tester);
      await tapKey(tester, 'nfs-delete-4');
      await enter(tester, 'nfs-confirmation', 'NFS #4: /mnt/tank/media');
      await tapKey(tester, 'nfs-impact-ack');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('nfs-confirm')))
            .onPressed,
        isNotNull,
      );
      h.select(null);
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(
        identical(
          h.container.read(nfsSharesInventoryProvider).asData?.value,
          h.api.inventory,
        ),
        isTrue,
      );
      expect(find.text('Review is no longer current'), findsOneWidget);
      expect(find.byKey(const Key('nfs-confirmation')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('nfs-confirm')))
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'pending review cannot revive after disconnect and same-object restoration',
    (tester) async {
      final pending = Completer<NfsShareReview>();
      final fake = NfsFake()..onReview = (_) => pending.future;
      final h = await pumpNfs(tester, fake: fake);
      await reveal(tester, find.byKey(const Key('nfs-delete-4')));
      await tester.tap(find.byKey(const Key('nfs-delete-4')));
      await tester.pump();
      h.select(null);
      h.select(h.session);
      await tester.pump();
      pending.complete(
        NfsShareReview(
          action: NfsShareAction.delete,
          target: 'NFS #4: /mnt/tank/media',
          identity: 'GUID 100',
          changes: [],
          warnings: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NfsShareReviewDialog), findsNothing);
      expect(fake.writes, isEmpty);
    },
  );
  testWidgets(
    '320px 200 percent review uses one bounded scroll with keyboard and reachable impact and actions',
    (tester) async {
      final h = await pumpNfs(tester, width: 320, scale: 2);
      await tapKey(tester, 'nfs-delete-4');
      final dialog = find.byType(NfsShareReviewDialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      await enter(tester, 'nfs-confirmation', 'NFS #4: /mnt/tank/media');
      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final scroll = find.byKey(const Key('nfs-review-scroll'));
      expect(tester.getSize(scroll).height, lessThan(900 - 340));
      final checkbox = find.descendant(
        of: find.byKey(const Key('nfs-impact-ack')),
        matching: find.byType(Checkbox),
      );
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      expect(checkbox.hitTestable(), findsOneWidget);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('nfs-confirm'));
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      expect(confirm.hitTestable(), findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      final cancel = find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, 'Cancel'),
      );
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      expect(cancel.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(h.api.writes, isEmpty);
    },
  );
  for (final width in [320.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final light in [false, true]) {
        testWidgets(
          'native inventory/editor/review fit ${width}px text $scale ${light ? 'light' : 'dark'}',
          (tester) async {
            final h = await pumpNfs(
              tester,
              width: width,
              scale: scale,
              light: light,
            );
            expect(tester.takeException(), isNull);
            await tapKey(tester, 'nfs-edit-4');
            await enter(tester, 'nfs-comment', 'Changed');
            tester.view.viewInsets = const FakeViewPadding(bottom: 250);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            tester.view.resetViewInsets();
            await tester.pumpAndSettle();
            await tapKey(tester, 'nfs-review');
            expect(find.byType(NfsShareReviewDialog), findsOneWidget);
            await enter(tester, 'nfs-confirmation', 'NFS #4: /mnt/tank/media');
            await tapKey(tester, 'nfs-impact-ack');
            expect(tester.takeException(), isNull);
            expect(h.api.writes, isEmpty);
          },
        );
      }
    }
  }
  test(
    'const-compatible preview is connector-free and rejects every mutation',
    () async {
      const preview = Preview();
      final i = await preview.loadNfsShares();
      expect(i.shares, hasLength(3));
      final request = NfsShareRequest(
        inventory: i,
        action: NfsShareAction.delete,
        share: i.shares.first,
      );
      final review = await preview.reviewNfsShare(request);
      expect(review.warnings.join(), contains('SAMPLE'));
      expect(
        (await preview.executeNfsShare(review, review.target)).outcome,
        NfsShareOutcome.rejected,
      );
      expect(identical(i, await preview.loadNfsShares()), true);
    },
  );
}

class Preview with NfsSharesPreviewAdapter {
  const Preview();
}
