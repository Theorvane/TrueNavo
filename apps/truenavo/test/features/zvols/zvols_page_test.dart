import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/sample/zvols_preview.dart';
import 'package:truenavo/features/zvols/zvols_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'zvols_fakes.dart';

Future<ZvolsHarness> pumpZvols(
  WidgetTester tester, {
  ZvolsFake? fake,
  bool editor = false,
  ZvolEntry? volume,
  double scale = 1,
  double? width,
}) async {
  final h = ZvolsHarness(fake: fake);
  addTearDown(h.dispose);
  if (width != null) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }
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
        home: editor
            ? Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => ZvolEditorDialog(
                        session: h.session,
                        inventory: h.api.inventory,
                        volume: volume,
                      ),
                    ),
                    child: const Text('Open test editor'),
                  ),
                ),
              )
            : const ZvolsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (editor) {
    await tester.tap(find.text('Open test editor'));
    await tester.pumpAndSettle();
  }
  return h;
}

Future<void> revealZvol(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      maxScrolls: 40,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> tapZvol(WidgetTester tester, String key) async {
  final base = find.byKey(Key(key));
  final finder = key == 'zvol-thin' || key == 'zvol-readonly'
      ? find.descendant(of: base, matching: find.byType(Switch))
      : base;
  await revealZvol(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enterZvol(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await revealZvol(tester, finder);
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> prepareCreate(WidgetTester tester) async {
  await enterZvol(tester, 'zvol-name', 'new_disk');
  await tapZvol(tester, 'zvol-prepare');
}

void main() {
  testWidgets(
    'inventory remains read-only and chart describes counts, not capacity',
    (tester) async {
      final h = await pumpZvols(tester);
      expect(find.text('Virtual block storage'), findsOneWidget);
      expect(find.text('Thin · 1'), findsOneWidget);
      expect(find.text('Reserved · 1'), findsOneWidget);
      expect(find.text('Custom reservation · 1'), findsOneWidget);
      expect(
        find.text('Returned volume counts, not guest usage or pool capacity.'),
        findsOneWidget,
      );
      expect(h.api.reads, 1);
      expect(h.api.writes, isEmpty);
      await tapZvol(tester, 'zvol-edit-${zvolVolume.id}');
      expect(find.text('Edit / grow Zvol'), findsOneWidget);
      expect(
        find.textContaining('Existing block size 16384 bytes is fixed'),
        findsOneWidget,
      );
      expect(h.api.recommendations, isEmpty);
    },
  );

  testWidgets(
    'missing dependency permission keeps inventory but disables every write entry',
    (tester) async {
      final h = await pumpZvols(
        tester,
        fake: ZvolsFake(methods: zvolMethods.difference({'vm.device.query'})),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('zvol-create')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(Key('zvol-edit-${zvolVolume.id}')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(Key('zvol-delete-${zvolVolume.id}')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'inventory error is redacted and retries only after explicit read action',
    (tester) async {
      final api = ZvolsFake()
        ..onLoad = () => Future.error(StateError('private credential payload'));
      final h = await pumpZvols(tester, fake: api);
      expect(find.textContaining('private credential'), findsNothing);
      expect(
        find.text(
          'Storage could not be loaded. No background retries are running.',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 10));
      expect(api.reads, 1);
      api.onLoad = () async => api.inventory;
      await tester.tap(find.text('Retry read'));
      await tester.pumpAndSettle();
      expect(api.reads, 2);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'create uses recommendation and exact bytes; cancellation does not dispatch',
    (tester) async {
      final api = ZvolsFake()..onRecommendation = (_) async => '32K';
      final h = await pumpZvols(tester, fake: api, editor: true);
      expect(api.recommendations, [same(zvolParent)]);
      expect(find.textContaining('Server recommendation: 32K'), findsOneWidget);
      await enterZvol(tester, 'zvol-name', 'new_disk');
      await tapZvol(tester, 'zvol-thin');
      await tapZvol(tester, 'zvol-prepare');
      expect(api.creates.single.sizeBytes, 10737418240);
      expect(api.creates.single.blockSize, '32K');
      expect(api.creates.single.thin, true);
      expect(find.text('Target: tank/virtual_disks/new_disk'), findsOneWidget);
      expect(find.text('Logical size: 10737418240 bytes'), findsOneWidget);
      expect(api.writes, isEmpty);
      await tester.tap(
        find.descendant(
          of: find.byType(ZvolReviewDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ZvolReviewDialog), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'recommendation failure blocks review and supports explicit retry only',
    (tester) async {
      final api = ZvolsFake()
        ..onRecommendation = (_) => Future.error(StateError('hidden key'));
      final h = await pumpZvols(tester, fake: api, editor: true);
      expect(find.textContaining('hidden key'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('zvol-prepare')))
            .onPressed,
        isNull,
      );
      expect(api.recommendations.length, 1);
      api.onRecommendation = (_) async => '16K';
      final retry = find.text('Retry recommendation read');
      await revealZvol(tester, retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(api.recommendations.length, 2);
      expect(find.textContaining('Server recommendation: 16K'), findsOneWidget);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'invalid create name and unchanged edit never request a server review',
    (tester) async {
      final h = await pumpZvols(tester, editor: true);
      await enterZvol(tester, 'zvol-name', '../wrong');
      await tapZvol(tester, 'zvol-prepare');
      expect(
        find.textContaining('Enter a simple new child name'),
        findsOneWidget,
      );
      expect(h.api.creates, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'thin growth preserves fixed block and submits only the reviewed change',
    (tester) async {
      final h = await pumpZvols(tester, editor: true, volume: zvolVolume);
      await tapZvol(tester, 'zvol-prepare');
      expect(find.text('Select at least one changed setting.'), findsOneWidget);
      expect(h.api.updates, isEmpty);
      await enterZvol(tester, 'zvol-size', '80');
      await tapZvol(tester, 'zvol-prepare');
      expect(h.api.updates.single.volume, same(zvolVolume));
      expect(h.api.updates.single.sizeBytes, 85899345920);
      expect(h.api.updates.single.compression, null);
      expect(h.api.updates.single.sync, null);
      expect(h.api.updates.single.readonly, null);
      expect(h.api.recommendations, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'reserved growth is disabled while non-size edits remain supported',
    (tester) async {
      final h = await pumpZvols(tester, editor: true, volume: reservedZvol);
      expect(
        tester.widget<TextField>(find.byKey(const Key('zvol-size'))).enabled,
        false,
      );
      expect(
        find.textContaining('Reserved-volume growth is unavailable here'),
        findsOneWidget,
      );
      await tapZvol(tester, 'zvol-readonly');
      await tapZvol(tester, 'zvol-prepare');
      expect(h.api.updates.single.volume, same(reservedZvol));
      expect(h.api.updates.single.sizeBytes, null);
      expect(h.api.updates.single.readonly, true);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'exact confirmation is required and one reviewed create is sent',
    (tester) async {
      final h = await pumpZvols(tester, editor: true);
      await prepareCreate(tester);
      final submit = find.byKey(const Key('zvol-confirm-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await enterZvol(
        tester,
        'zvol-confirmation',
        'tank/virtual_disks/new_disk ',
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await enterZvol(
        tester,
        'zvol-confirmation',
        'tank/virtual_disks/new_disk',
      );
      await tapZvol(tester, 'zvol-confirm-submit');
      expect(h.api.writes.length, 1);
      expect(h.api.writes.single.action, ZvolAction.create);
      expect(h.api.confirmations, ['tank/virtual_disks/new_disk']);
      expect(find.byType(ZvolReviewDialog), findsNothing);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'delete review names irreversible target and cancel never executes',
    (tester) async {
      final h = await pumpZvols(tester);
      await tapZvol(tester, 'zvol-delete-${zvolVolume.id}');
      expect(h.api.deletes, [same(zvolVolume)]);
      expect(find.text('Target: ${zvolVolume.id}'), findsOneWidget);
      expect(
        find.text('Permanently destroys this virtual disk.'),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(ZvolReviewDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'session switch hides previous editor and review values immediately',
    (tester) async {
      final h = await pumpZvols(tester, editor: true);
      await prepareCreate(tester);
      h.select(h.newSession(endpoint: 'wss://different.example/api/current'));
      await tester.pumpAndSettle();
      expect(find.text('Connection changed'), findsWidgets);
      expect(find.byKey(const Key('zvol-confirmation')), findsNothing);
      expect(find.text('Target: tank/virtual_disks/new_disk'), findsNothing);
      expect(find.byKey(const Key('zvol-name')), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'late recommendation cannot restore values from previous session',
    (tester) async {
      final recommendation = Completer<String>();
      final api = ZvolsFake()..onRecommendation = (_) => recommendation.future;
      final h = ZvolsHarness(fake: api);
      addTearDown(h.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: TrueNavoTheme.dark(),
            home: Scaffold(
              body: ZvolEditorDialog(
                session: h.session,
                inventory: api.inventory,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      h.select(h.newSession(endpoint: 'wss://different.example/api/current'));
      await tester.pump();
      recommendation.complete('64K');
      await tester.pumpAndSettle();
      expect(find.text('Connection changed'), findsOneWidget);
      expect(find.textContaining('Server recommendation'), findsNothing);
      expect(find.byKey(const Key('zvol-name')), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    '320px 200% chart inventory is responsive and semantically labelled',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final h = await pumpZvols(tester, width: 320, scale: 2);
        await revealZvol(tester, find.byType(ZvolProvisioningChart));
        expect(
          find.bySemanticsLabel(
            'Zvol provisioning: 1 thin, 1 reserved, 1 custom.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), null);
        expect(h.api.writes, isEmpty);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('320px 200% create and review are scrollable without overflow', (
    tester,
  ) async {
    final h = await pumpZvols(tester, editor: true, width: 320, scale: 2);
    await enterZvol(tester, 'zvol-name', 'new_disk');
    await tapZvol(tester, 'zvol-thin');
    await tapZvol(tester, 'zvol-prepare');
    await enterZvol(tester, 'zvol-confirmation', 'tank/virtual_disks/new_disk');
    expect(h.api.creates.single.thin, true);
    await revealZvol(tester, find.byKey(const Key('zvol-confirm-submit')));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('zvol-confirm-submit')))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), null);
    expect(h.api.writes, isEmpty);
  });

  testWidgets('320px 200% thin growth editor does not overflow', (
    tester,
  ) async {
    final h = await pumpZvols(
      tester,
      editor: true,
      volume: zvolVolume,
      width: 320,
      scale: 2,
    );
    await enterZvol(tester, 'zvol-size', '80');
    await tapZvol(tester, 'zvol-prepare');
    await revealZvol(tester, find.byKey(const Key('zvol-confirmation')));
    expect(h.api.updates.single.sizeBytes, 85899345920);
    expect(tester.takeException(), null);
    expect(h.api.writes, isEmpty);
  });

  testWidgets('empty chart does not infer usage or percentages', (
    tester,
  ) async {
    final h = await pumpZvols(
      tester,
      fake: ZvolsFake(
        inventory: ZvolInventory(parents: [zvolParent], volumes: []),
      ),
    );
    expect(
      find.text('No volume data; no percentages are inferred.'),
      findsOneWidget,
    );
    expect(find.text('Thin · 0'), findsOneWidget);
    expect(h.api.writes, isEmpty);
    expect(tester.takeException(), null);
  });

  test(
    'synthetic preview has no transport and rejects all reviewed mutations',
    () async {
      final preview = NoTransportZvolPreview();
      final inventory = await preview.loadZvols();
      expect(inventory.volumes.length, 3);
      expect(
        await preview.loadZvolRecommendedBlockSize(inventory.parents.single),
        '16K',
      );
      final thin = inventory.volumes.firstWhere(
        (v) => v.refreservationBytes == 0,
      );
      final reviews = [
        await preview.reviewZvolCreate(
          ZvolCreate(
            parent: inventory.parents.single,
            name: 'new',
            sizeBytes: 10737418240,
            thin: true,
          ),
        ),
        await preview.reviewZvolUpdate(
          ZvolUpdate(volume: thin, sizeBytes: thin.sizeBytes + 1073741824),
        ),
        await preview.reviewZvolDelete(thin),
      ];
      for (final review in reviews) {
        final result = await preview.executeZvolReview(review, review.target);
        expect(result.outcome, ZvolOutcome.rejected);
        expect(result.message, contains('all writes are disabled'));
      }
      expect(() => inventory.volumes.clear(), throwsUnsupportedError);
    },
  );
}

class NoTransportZvolPreview with ZvolsPreviewAdapter {}
