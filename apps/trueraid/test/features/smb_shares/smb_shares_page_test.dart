import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/smb_shares_preview.dart';
import 'package:trueraid/features/smb_shares/smb_share_editor.dart';
import 'package:trueraid/features/smb_shares/smb_shares_controller.dart';
import 'package:trueraid/features/smb_shares/smb_shares_page.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'smb_shares_fakes.dart';

class _Preview with SmbSharesPreviewAdapter {
  const _Preview();
}

Future<SmbHarness> pumpSmb(
  WidgetTester tester, {
  SmbFake? fake,
  bool editor = false,
  bool create = false,
  double width = 800,
  double scale = 1,
  bool light = false,
  bool awaitInventory = true,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = SmbHarness(fake: fake);
  addTearDown(h.dispose);
  if (awaitInventory) await h.container.read(smbSharesInventoryProvider.future);
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
            ? SmbShareEditorPage(
                session: h.session,
                inventory: h.api.inventory,
                share: create ? null : h.api.inventory.shares.first,
              )
            : const SmbSharesPage(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return h;
}

Future<void> revealSmb(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  if (finder.evaluate().isEmpty) {
    final scroll = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pumpAndSettle();
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        400,
        maxScrolls: 100,
        scrollable: scroll,
      );
    }
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapSmb(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await revealSmb(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> typeSmb(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(Key(key));
  await revealSmb(tester, finder);
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'inventory chart reports enablement, not clients or health; null lock stays unknown',
    (tester) async {
      await pumpSmb(
        tester,
        fake: SmbFake(
          inventory: smbInventory(
            locked: null,
            blockedReason: 'Unknown lock state',
          ),
        ),
      );
      await revealSmb(
        tester,
        find.byKey(const Key('smb-enablement-semantics')),
      );
      final semantics = tester.widget<Semantics>(
        find.byKey(const Key('smb-enablement-semantics')),
      );
      expect(
        semantics.properties.label,
        contains('1 enabled, 1 disabled, 2 total'),
      );
      expect(
        semantics.properties.label,
        contains('Not clients, capacity or health'),
      );
      await revealSmb(tester, find.text('Dataset lock: Unknown'));
      expect(find.text('Dataset lock: Unknown'), findsOneWidget);
      expect(find.text('Dataset lock: Unlocked'), findsNothing);
    },
  );
  testWidgets(
    'zero inventory stays zero without inferred percentages or health',
    (tester) async {
      await pumpSmb(
        tester,
        fake: SmbFake(
          inventory: smbInventory(empty: true, service: 'UNKNOWN', boot: false),
        ),
      );
      expect(find.text('UNKNOWN'), findsOneWidget);
      expect(find.text('Start at boot: Disabled'), findsOneWidget);
      await revealSmb(
        tester,
        find.text('No shares returned; no percentage is inferred.'),
      );
      expect(find.text('Enabled · 0'), findsOneWidget);
      expect(find.text('Disabled · 0'), findsOneWidget);
      expect(find.textContaining('100%'), findsNothing);
    },
  );
  testWidgets(
    'stopped service is not shown as running or started by share creation',
    (tester) async {
      final h = await pumpSmb(
        tester,
        fake: SmbFake(inventory: smbInventory(service: 'STOPPED', boot: false)),
      );
      expect(find.text('STOPPED'), findsOneWidget);
      expect(
        find.text('Stopped. Saving a share does not start SMB.'),
        findsOneWidget,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('summary cards are equal height on wide screens', (tester) async {
    await pumpSmb(tester);
    expect(
      tester.getSize(find.byKey(const Key('smb-summary-count'))).height,
      tester.getSize(find.byKey(const Key('smb-summary-service'))).height,
    );
  });
  for (final light in [false, true]) {
    testWidgets(
      '320px 200% ${light ? 'light' : 'dark'} inventory and ring remain readable',
      (tester) async {
        await pumpSmb(tester, width: 320, scale: 2, light: light);
        await revealSmb(tester, find.byKey(const Key('smb-enablement-ring')));
        expect(
          tester.getSize(find.byKey(const Key('smb-enablement-ring'))),
          const Size(112, 112),
        );
        await revealSmb(tester, find.byKey(const Key('smb-delete-4')));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'create uses existing root and explicit settings; cancellation sends nothing',
    (tester) async {
      final h = await pumpSmb(tester, editor: true, create: true);
      await typeSmb(tester, 'smb-name', 'New files');
      await typeSmb(tester, 'smb-comment', 'Project files');
      await tapSmb(tester, 'smb-readonly');
      await tapSmb(tester, 'smb-enabled');
      await tapSmb(tester, 'smb-review');
      expect(h.api.reviews.single.action, SmbShareAction.create);
      expect(h.api.reviews.single.dataset, isNotNull);
      expect(h.api.reviews.single.settings!.name, 'New files');
      expect(h.api.reviews.single.settings!.comment, 'Project files');
      expect(h.api.reviews.single.settings!.readonly, isTrue);
      expect(h.api.reviews.single.settings!.enabled, isFalse);
      await tapSmb(tester, 'smb-confirm-cancel');
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'edit keeps name and path immutable and requires exact typed impact confirmation',
    (tester) async {
      final h = await pumpSmb(tester, editor: true);
      expect(find.byKey(const Key('smb-name')), findsNothing);
      expect(find.byKey(const Key('smb-immutable-name')), findsOneWidget);
      await typeSmb(tester, 'smb-comment', 'Updated comment');
      await tapSmb(tester, 'smb-review');
      expect(h.api.reviews.single.settings!.name, 'Team files');
      expect(h.api.reviews.single.dataset, isNull);
      await typeSmb(tester, 'smb-confirm-target', 'team files');
      await tapSmb(tester, 'smb-confirm-impact');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('smb-confirm-submit')))
            .onPressed,
        isNull,
      );
      await typeSmb(tester, 'smb-confirm-target', 'Team files ');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('smb-confirm-submit')))
            .onPressed,
        isNull,
      );
      await typeSmb(tester, 'smb-confirm-target', 'Team files');
      await tapSmb(tester, 'smb-confirm-submit');
      expect(h.api.writes.length, 1);
      expect(h.api.writes.single.action, SmbShareAction.update);
    },
  );
  testWidgets('unchanged edit and duplicate name cannot request review', (
    tester,
  ) async {
    final h = await pumpSmb(tester, editor: true);
    await tapSmb(tester, 'smb-review');
    expect(h.api.reviews, isEmpty);
    expect(
      find.text('Change at least one setting before reviewing.'),
      findsOneWidget,
    );
  });
  testWidgets('duplicate creation name is rejected case-insensitively', (
    tester,
  ) async {
    final h = await pumpSmb(tester, editor: true, create: true);
    await typeSmb(tester, 'smb-name', 'team FILES');
    await tapSmb(tester, 'smb-review');
    expect(h.api.reviews, isEmpty);
    expect(
      find.text('Share names must be unique, ignoring case.'),
      findsOneWidget,
    );
  });
  testWidgets(
    'guarded delete shows client impact and preserves dataset scope',
    (tester) async {
      final h = await pumpSmb(tester);
      await tapSmb(tester, 'smb-delete-4');
      expect(h.api.reviews.single.action, SmbShareAction.delete);
      expect(h.api.reviews.single.settings, isNull);
      await revealSmb(
        tester,
        find.textContaining('The dataset and files are not deleted.'),
      );
      await typeSmb(tester, 'smb-confirm-target', 'Team files');
      await tapSmb(tester, 'smb-confirm-impact');
      await tapSmb(tester, 'smb-confirm-submit');
      expect(h.api.writes.single.action, SmbShareAction.delete);
    },
  );
  testWidgets('unsupported purpose remains inspect-only and cannot delete', (
    tester,
  ) async {
    final h = await pumpSmb(tester);
    await revealSmb(tester, find.byKey(const Key('smb-delete-5')));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('smb-delete-5')))
          .onPressed,
      isNull,
    );
    await tapSmb(tester, 'smb-edit-5');
    await revealSmb(tester, find.byKey(const Key('smb-review')));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('smb-review')))
          .onPressed,
      isNull,
    );
    expect(h.api.reviews, isEmpty);
  });
  testWidgets(
    'missing write methods leave inventory readable and edits disabled',
    (tester) async {
      final h = await pumpSmb(
        tester,
        fake: SmbFake(
          caps: const SmbSharesCapabilities(
            connected: true,
            versionSupported: true,
            available: true,
            canCreate: false,
            canUpdate: false,
            canDelete: false,
          ),
        ),
      );
      await revealSmb(tester, find.byKey(const Key('smb-create')));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('smb-create')))
            .onPressed,
        isNull,
      );
      await tapSmb(tester, 'smb-edit-4');
      await revealSmb(tester, find.byKey(const Key('smb-review')));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('smb-review')))
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('unsupported version does not invent an empty inventory', (
    tester,
  ) async {
    final h = await pumpSmb(
      tester,
      awaitInventory: false,
      fake: SmbFake(
        caps: const SmbSharesCapabilities(
          connected: true,
          versionSupported: false,
          available: true,
          canCreate: false,
          canUpdate: false,
          canDelete: false,
        ),
      ),
    );
    expect(find.text('SMB shares unavailable'), findsOneWidget);
    expect(find.byKey(const Key('smb-enablement-ring')), findsNothing);
    expect(h.api.reads, 0);
  });
  testWidgets('read errors are redacted with manual retry only', (
    tester,
  ) async {
    final fake = SmbFake()
      ..onLoad = () => Future.error(StateError('secret body'));
    final h = await pumpSmb(tester, fake: fake, awaitInventory: false);
    expect(find.text('SMB inventory unavailable'), findsOneWidget);
    expect(find.textContaining('secret body'), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(h.api.reads, 1);
    await tapSmb(tester, 'smb-retry');
    expect(h.api.reads, 2);
  });
  testWidgets(
    'draft permanently expires and clears fields across disconnect and same-object restoration',
    (tester) async {
      final h = await pumpSmb(tester, editor: true);
      await typeSmb(tester, 'smb-comment', 'Private draft');
      h.select(null);
      await tester.pumpAndSettle();
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(find.text('Draft is no longer current'), findsOneWidget);
      expect(find.text('Private draft'), findsNothing);
      expect(find.text('Team files'), findsNothing);
      expect(h.api.reviews, isEmpty);
    },
  );
  testWidgets(
    'inventory refresh expires editor even if same fixture object returns',
    (tester) async {
      final h = await pumpSmb(tester, editor: true);
      h.container.invalidate(smbSharesInventoryProvider);
      await tester.pumpAndSettle();
      expect(find.text('Draft is no longer current'), findsOneWidget);
      expect(h.api.reviews, isEmpty);
    },
  );
  testWidgets('open review expires on session change and cannot revive', (
    tester,
  ) async {
    final h = await pumpSmb(tester, editor: true);
    await typeSmb(tester, 'smb-comment', 'Changed');
    await tapSmb(tester, 'smb-review');
    h.select(null);
    await tester.pumpAndSettle();
    h.select(h.session);
    await tester.pumpAndSettle();
    expect(find.text('Review is no longer current'), findsOneWidget);
    expect(find.text('Team files'), findsNothing);
    expect(find.byKey(const Key('smb-confirm-target')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('smb-confirm-submit')))
          .onPressed,
      isNull,
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets('late review after transient session switch is discarded', (
    tester,
  ) async {
    final pending = Completer<SmbShareReview>();
    final fake = SmbFake()..onReview = (_) => pending.future;
    final h = await pumpSmb(tester, fake: fake, editor: true);
    await typeSmb(tester, 'smb-comment', 'Changed');
    await tapSmb(tester, 'smb-review');
    h.select(null);
    h.select(h.session);
    pending.complete(smbReview());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('smb-confirm-submit')), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('mismatched returned review never becomes confirmable', (
    tester,
  ) async {
    final fake = SmbFake()
      ..onReview = (_) async => SmbShareReview(
        action: SmbShareAction.delete,
        target: 'Other target',
        identity: 'wrong',
        changes: [],
        warnings: [],
      );
    final h = await pumpSmb(tester, fake: fake, editor: true);
    await typeSmb(tester, 'smb-comment', 'Changed');
    await tapSmb(tester, 'smb-review');
    expect(find.byKey(const Key('smb-confirm-submit')), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'unknown operation disables refresh and retains original target through disconnect',
    (tester) async {
      final fake = SmbFake()
        ..onExecute = () async => const SmbShareResult(
          SmbShareOutcome.unknown,
          'Inspect before reconnect.',
        );
      final h = await pumpSmb(tester, fake: fake);
      await h.container
          .read(smbSharesControllerProvider.notifier)
          .execute(
            expectedSession: h.session,
            review: smbReview(),
            confirmation: 'Team files',
          );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('smb-refresh')))
            .onPressed,
        isNull,
      );
      expect(find.text('Outcome needs verification'), findsOneWidget);
      h.select(null);
      await tester.pumpAndSettle();
      expect(find.text('Original target: Team files'), findsOneWidget);
      expect(find.text('Team files'), findsNothing);
      expect(find.byKey(const Key('smb-enablement-ring')), findsNothing);
    },
  );
  testWidgets(
    '320px 200% editor and review support scrolling and typed confirmation',
    (tester) async {
      final h = await pumpSmb(tester, editor: true, width: 320, scale: 2);
      await typeSmb(tester, 'smb-comment', 'Narrow layout');
      await tapSmb(tester, 'smb-review');
      await typeSmb(tester, 'smb-confirm-target', 'Team files');
      await tapSmb(tester, 'smb-confirm-impact');
      await tapSmb(tester, 'smb-confirm-submit');
      expect(h.api.writes.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('loading is not replaced by zero-share configuration', (
    tester,
  ) async {
    final pending = Completer<SmbShareInventory>();
    final fake = SmbFake()..onLoad = () => pending.future;
    final h = await pumpSmb(
      tester,
      fake: fake,
      awaitInventory: false,
      settle: false,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('smb-enablement-ring')), findsNothing);
    expect(find.text('No SMB shares were returned.'), findsNothing);
    expect(h.api.reads, 1);
    pending.complete(fake.inventory);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('smb-enablement-ring')), findsOneWidget);
  });
  testWidgets(
    'create selects unused eligible root and submits one confirmed request',
    (tester) async {
      final h = await pumpSmb(tester, editor: true, create: true);
      expect(
        tester
            .widget<DropdownButtonFormField<SmbShareDataset>>(
              find.byKey(const Key('smb-dataset')),
            )
            .initialValue!
            .id,
        'tank/new',
      );
      await typeSmb(tester, 'smb-name', 'New files');
      await tapSmb(tester, 'smb-review');
      await typeSmb(tester, 'smb-confirm-target', 'New files');
      await tapSmb(tester, 'smb-confirm-impact');
      await tapSmb(tester, 'smb-confirm-submit');
      expect(h.api.reviews.single.dataset!.id, 'tank/new');
      expect(h.api.writes.single.action, SmbShareAction.create);
    },
  );
  testWidgets('no unused eligible root keeps creation disabled', (
    tester,
  ) async {
    final inventory = smbInventory();
    await pumpSmb(
      tester,
      fake: SmbFake(
        inventory: SmbShareInventory(
          shares: inventory.shares,
          datasets: [inventory.datasets.first],
          serviceState: 'RUNNING',
          serviceEnabled: true,
        ),
      ),
    );
    await revealSmb(tester, find.byKey(const Key('smb-create')));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('smb-create')))
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'keyboard-visible 320px 200% review retains scrollable confirmation',
    (tester) async {
      final h = await pumpSmb(tester, editor: true, width: 320, scale: 2);
      await typeSmb(tester, 'smb-comment', 'Keyboard layout');
      await tapSmb(tester, 'smb-review');
      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await typeSmb(tester, 'smb-confirm-target', 'Team files');
      await tapSmb(tester, 'smb-confirm-impact');
      await tapSmb(tester, 'smb-confirm-submit');
      expect(h.api.writes.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'const synthetic preview uses immutable fixtures and rejects every write',
    () async {
      const preview = _Preview();
      final inventory = await preview.loadSmbShares();
      expect(inventory.enabledCount, 2);
      expect(inventory.disabledCount, 2);
      expect(() => inventory.shares.clear(), throwsUnsupportedError);
      expect(() => inventory.datasets.clear(), throwsUnsupportedError);
      for (final action in SmbShareAction.values) {
        final request = SmbShareRequest(
          inventory: inventory,
          action: action,
          share: action == SmbShareAction.create
              ? null
              : inventory.shares.first,
          dataset: action == SmbShareAction.create
              ? inventory.datasets.first
              : null,
          settings: action == SmbShareAction.delete
              ? null
              : SmbShareSettings(
                  name: action == SmbShareAction.create
                      ? 'New sample'
                      : inventory.shares.first.name,
                  comment: 'Changed',
                ),
        );
        final review = await preview.reviewSmbShare(request);
        expect(review.warnings.join(), contains('SAMPLE ONLY'));
        expect(
          (await preview.executeSmbShare(review, review.target)).outcome,
          SmbShareOutcome.rejected,
        );
      }
      expect(await preview.loadSmbShares(), same(inventory));
    },
  );
}
