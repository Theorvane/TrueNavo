import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/dev/quotas_preview.dart';
import 'package:truenavo/features/quotas/quotas_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'quotas_fakes.dart';

Finder key(String name) => find.byKey(Key(name));
Finder reviewText(String text) => find.descendant(
  of: find.byType(QuotaReviewDialog),
  matching: find.textContaining(text),
);

Future<void> reveal(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      220,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String name) async {
  await reveal(tester, key(name));
  await tester.tap(key(name));
  await tester.pumpAndSettle();
}

Future<void> mode(WidgetTester tester, String measure, String label) async {
  await tap(tester, 'quota-limit-$measure-mode');
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<QuotaHarness> pump(
  WidgetTester tester, {
  QuotaHarness? harness,
  double scale = 1,
  bool connected = true,
}) async {
  final h = harness ?? QuotaHarness();
  addTearDown(h.dispose);
  if (!connected) h.select(null);
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
        home: const QuotasPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> edit(
  WidgetTester tester, {
  String kind = 'USER',
  int id = 1000,
}) async {
  if (kind == 'GROUP') await tap(tester, 'quota-tab-group');
  await reveal(tester, key('quota-search'));
  await tester.enterText(key('quota-search'), '$id');
  await tester.pumpAndSettle();
  await tap(tester, 'quota-edit-$kind-$id');
}

Future<void> byteReview(WidgetTester tester, {String bytes = '2048'}) async {
  await edit(tester);
  await tap(tester, 'quota-identity-resolve');
  await mode(tester, 'bytes', 'Set a limit');
  await reveal(tester, key('quota-byte-limit'));
  await tester.enterText(key('quota-byte-limit'), bytes);
  await tap(tester, 'quota-review');
}

Future<void> confirm(
  WidgetTester tester, {
  String text = 'tank/shared USER 1000',
}) async {
  await reveal(tester, key('quota-confirm-text'));
  await tester.enterText(key('quota-confirm-text'), text);
  await tap(tester, 'quota-confirm-acknowledge');
  await tap(tester, 'quota-confirm-submit');
}

void main() {
  testWidgets(
    'inventory separates byte/object limits, unknown usage, and unlimited',
    (tester) async {
      final h = await pump(tester);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('3 user quota entries'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(key('quota-usage-USER-1000-bytes'))
            .value,
        0.5,
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              key('quota-usage-USER-1000-objects'),
            )
            .value,
        0.5,
      );
      expect(key('quota-usage-USER-1001-bytes'), findsNothing);
      expect(key('quota-usage-USER-1001-objects'), findsNothing);
      expect(key('quota-usage-USER-1002-bytes'), findsNothing);
      expect(key('quota-usage-USER-1002-objects'), findsNothing);
      expect(find.text('Used: Unavailable'), findsNWidgets(2));
      expect(find.text('Limit: Unlimited'), findsNWidgets(2));
      expect(h.api.datasetReads, 1);
      expect(h.api.inventoryReads, 1);
      expect(h.api.resolutions, 0);
      expect(h.api.executions, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'over-limit bar is clamped and uses critical color without hiding exact usage',
    (tester) async {
      await pump(tester);
      await tap(tester, 'quota-tab-group');
      final bar = tester.widget<LinearProgressIndicator>(
        key('quota-usage-GROUP-2000-bytes'),
      );
      expect(bar.value, 1);
      expect(
        bar.color,
        tester
            .element(key('quota-usage-GROUP-2000-bytes'))
            .tdTheme
            .statusCritical,
      );
      expect(find.text('Over limit'), findsOneWidget);
      expect(find.text('Used: 8.0 KiB (8192 bytes)'), findsOneWidget);
    },
  );

  testWidgets('at-limit uses warning color and an explicit label', (
    tester,
  ) async {
    final h = QuotaHarness();
    h.api.entries = const [
      QuotaEntry(
        kind: QuotaKind.user,
        id: 1000,
        name: 'alice',
        byteLimit: 100,
        objectLimit: 0,
        usedBytes: 100,
      ),
    ];
    await pump(tester, harness: h);
    expect(find.text('At limit'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      key('quota-usage-USER-1000-bytes'),
    );
    expect(
      bar.color,
      tester.element(key('quota-usage-USER-1000-bytes')).tdTheme.statusWarning,
    );
  });

  for (final scenario in [
    'offline',
    'unsupported',
    'unavailable',
    'missing-endpoint',
  ]) {
    testWidgets('$scenario avoids dataset reads and editing', (tester) async {
      final h = QuotaHarness();
      h.api.versionSupported = scenario != 'unsupported';
      h.api.available = scenario != 'unavailable';
      if (scenario == 'missing-endpoint') {
        h.select(h.newSession(endpoint: null));
      }
      await pump(tester, harness: h, connected: scenario != 'offline');
      expect(find.text('Quotas unavailable'), findsOneWidget);
      expect(h.api.datasetReads, 0);
      expect(key('quota-add'), findsNothing);
    });
  }

  testWidgets('user and group write permissions are independently gated', (
    tester,
  ) async {
    final h = QuotaHarness();
    h.api.canSetUser = false;
    await pump(tester, harness: h);
    expect(tester.widget<FilledButton>(key('quota-add')).onPressed, isNull);
    expect(
      tester.widget<OutlinedButton>(key('quota-edit-USER-1000')).onPressed,
      isNull,
    );
    await tap(tester, 'quota-tab-group');
    expect(tester.widget<FilledButton>(key('quota-add')).onPressed, isNotNull);
    expect(h.api.executions, 0);
  });

  testWidgets('protected dataset selection does not load identity quota rows', (
    tester,
  ) async {
    final h = await pump(tester);
    await tap(tester, 'quota-dataset-tank/shared');
    await tester.tap(find.text('tank/protected').last);
    await tester.pumpAndSettle();
    expect(find.text('Dataset protected'), findsOneWidget);
    expect(key('quota-add'), findsNothing);
    expect(h.api.inventoryReads, 1);
  });

  testWidgets(
    'existing identity must resolve before a review and read-only opening makes no write',
    (tester) async {
      final h = await pump(tester);
      await edit(tester);
      expect(
        tester.widget<FilledButton>(key('quota-review')).onPressed,
        isNull,
      );
      expect(h.api.resolutions, 0);
      await tap(tester, 'quota-identity-resolve');
      expect(find.text('User alice (UID 1000)'), findsOneWidget);
      expect(find.text('Source: LOCAL'), findsOneWidget);
      expect(find.text('Numeric target: USER 1000'), findsOneWidget);
      expect(h.api.resolutions, 1);
      await tap(tester, 'quota-review');
      expect(key('quota-editor-error'), findsOneWidget);
      expect(h.api.reviews, 0);
      expect(h.api.executions, 0);
    },
  );

  testWidgets('wrong resolved numeric identity cannot reach review', (
    tester,
  ) async {
    final h = QuotaHarness();
    h.api.wrongIdentity = true;
    await pump(tester, harness: h);
    await edit(tester);
    await tap(tester, 'quota-identity-resolve');
    expect(find.textContaining('did not match'), findsOneWidget);
    expect(tester.widget<FilledButton>(key('quota-review')).onPressed, isNull);
    expect(h.api.reviews, 0);
  });

  testWidgets(
    'numeric lookup rejects root, usernames, fractions and overflowing IDs locally',
    (tester) async {
      final h = await pump(tester);
      await tap(tester, 'quota-add');
      for (final invalid in ['', '0', 'alice', '-1', '1.5', '4294967295']) {
        await tester.enterText(key('quota-identity-id'), invalid);
        await tap(tester, 'quota-identity-resolve');
        expect(key('quota-editor-error'), findsOneWidget);
      }
      expect(h.api.resolutions, 0);
      expect(h.api.executions, 0);
    },
  );

  testWidgets(
    'new directory identity can receive two limits while usage remains unknown',
    (tester) async {
      final h = await pump(tester);
      await tap(tester, 'quota-add');
      await tester.enterText(key('quota-identity-id'), '5000');
      await tap(tester, 'quota-identity-resolve');
      expect(find.text('User directory-member (UID 5000)'), findsOneWidget);
      expect(find.text('Source: LDAP'), findsOneWidget);
      expect(find.text('SID: S-1-5-21-5000'), findsOneWidget);
      expect(find.text('Reported byte usage: Unavailable'), findsOneWidget);
      await mode(tester, 'bytes', 'Set a limit');
      await tester.enterText(key('quota-byte-limit'), '1048576');
      await mode(tester, 'objects', 'Set a limit');
      await tester.enterText(key('quota-object-limit'), '100');
      await tap(tester, 'quota-review');
      expect(reviewText('tank/shared USER 5000'), findsOneWidget);
      expect(h.api.lastChange!.byteLimit, 1048576);
      expect(h.api.lastChange!.objectLimit, 100);
      expect(h.api.lastChange!.identity.id, 5000);
      await confirm(tester, text: 'tank/shared USER 5000');
      expect(h.api.executions, 1);
    },
  );

  testWidgets(
    'byte change preserves unselected object limit and requires exact full confirmation plus acknowledgement',
    (tester) async {
      final h = await pump(tester);
      await byteReview(tester);
      expect(h.api.lastChange!.byteLimit, 2048);
      expect(h.api.lastChange!.objectLimit, isNull);
      expect(reviewText('Byte limit: 1024 → 2048'), findsOneWidget);
      await tester.enterText(
        key('quota-confirm-text'),
        'tank/shared USER 1000',
      );
      await tester.pump();
      expect(
        tester.widget<FilledButton>(key('quota-confirm-submit')).onPressed,
        isNull,
      );
      await tap(tester, 'quota-confirm-acknowledge');
      for (final invalid in [
        '1000',
        'tank/shared GROUP 1000',
        'tank/shared USER 1000 ',
        'tank/shared user 1000',
      ]) {
        await tester.enterText(key('quota-confirm-text'), invalid);
        await tester.pump();
        expect(
          tester.widget<FilledButton>(key('quota-confirm-submit')).onPressed,
          isNull,
        );
      }
      await tester.enterText(
        key('quota-confirm-text'),
        'tank/shared USER 1000',
      );
      await tap(tester, 'quota-confirm-submit');
      expect(h.api.executions, 1);
      expect(h.api.confirmation, 'tank/shared USER 1000');
      expect(h.state.result!.outcome, QuotaOutcome.verified);
    },
  );

  testWidgets('Unlimited explicitly removes only the chosen object limit', (
    tester,
  ) async {
    final h = await pump(tester);
    await edit(tester);
    await tap(tester, 'quota-identity-resolve');
    await mode(tester, 'objects', 'Unlimited');
    await tap(tester, 'quota-review');
    expect(reviewText('Object limit: 10 → Unlimited'), findsOneWidget);
    expect(h.api.lastChange!.objectLimit, 0);
    expect(h.api.lastChange!.byteLimit, isNull);
    await tap(tester, 'quota-confirm-cancel');
    expect(h.api.executions, 0);
  });

  testWidgets(
    'below-usage byte limits remain reviewable with an explicit warning',
    (tester) async {
      final h = await pump(tester);
      await byteReview(tester, bytes: '128');
      expect(reviewText('below reported usage'), findsOneWidget);
      expect(h.api.lastChange!.byteLimit, 128);
      await tap(tester, 'quota-confirm-cancel');
      expect(h.api.executions, 0);
    },
  );

  testWidgets(
    'fractional negative zero and oversized explicit limits cannot be reviewed',
    (tester) async {
      final h = await pump(tester);
      await edit(tester);
      await tap(tester, 'quota-identity-resolve');
      await mode(tester, 'bytes', 'Set a limit');
      for (final invalid in ['-1', '1.5', '0', '9007199254740992']) {
        await tester.enterText(key('quota-byte-limit'), invalid);
        await tap(tester, 'quota-review');
        expect(key('quota-editor-error'), findsOneWidget);
      }
      expect(h.api.reviews, 0);
    },
  );

  testWidgets(
    'group quota review carries numeric GID and never resolves a user',
    (tester) async {
      final h = await pump(tester);
      await edit(tester, kind: 'GROUP', id: 2000);
      await tap(tester, 'quota-identity-resolve');
      expect(find.text('Group studio (GID 2000)'), findsOneWidget);
      await mode(tester, 'objects', 'Set a limit');
      await tester.enterText(key('quota-object-limit'), '200');
      await tap(tester, 'quota-review');
      expect(reviewText('tank/shared GROUP 2000'), findsOneWidget);
      expect(h.api.lastChange!.identity.kind, QuotaKind.group);
      await confirm(tester, text: 'tank/shared GROUP 2000');
      expect(h.api.executions, 1);
    },
  );

  testWidgets(
    'session change permanently clears the resolved identity and all limit drafts',
    (tester) async {
      final h = await pump(tester);
      await edit(tester);
      await tap(tester, 'quota-identity-resolve');
      await mode(tester, 'bytes', 'Set a limit');
      await tester.enterText(key('quota-byte-limit'), '7654321');
      h.select(null);
      await tester.pumpAndSettle();
      expect(find.text('Connection changed'), findsOneWidget);
      expect(find.text('7654321'), findsNothing);
      expect(find.text('User alice (UID 1000)'), findsNothing);
      expect(key('quota-byte-limit'), findsNothing);
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(key('quota-review'), findsNothing);
      expect(h.api.executions, 0);
    },
  );

  testWidgets(
    'session change permanently removes the review target and typed confirmation',
    (tester) async {
      final h = await pump(tester);
      await byteReview(tester);
      await tester.enterText(
        key('quota-confirm-text'),
        'tank/shared USER 1000',
      );
      h.select(null);
      await tester.pumpAndSettle();
      expect(reviewText('tank/shared'), findsNothing);
      expect(key('quota-confirm-text'), findsNothing);
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(key('quota-confirm-submit'), findsNothing);
      await tap(tester, 'quota-review-close');
      expect(h.api.executions, 0);
    },
  );

  testWidgets('late numeric lookup cannot repopulate an expired form', (
    tester,
  ) async {
    final h = await pump(tester);
    await edit(tester);
    final pending = Completer<QuotaIdentity>();
    h.api.pendingIdentity = pending.future;
    await reveal(tester, key('quota-identity-resolve'));
    await tester.tap(key('quota-identity-resolve'));
    await tester.pump();
    h.select(null);
    await tester.pumpAndSettle();
    pending.complete(
      const QuotaIdentity(
        kind: QuotaKind.user,
        id: 1000,
        name: 'late-private-name',
        source: 'LOCAL',
        local: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('late-private-name'), findsNothing);
    expect(key('quota-review'), findsNothing);
    expect(h.api.reviews, 0);
  });

  testWidgets(
    'new session clears old dataset and quota inventory during pending discovery',
    (tester) async {
      final h = await pump(tester);
      final pending = Completer<List<QuotaDataset>>();
      h.api.pendingDatasets = pending.future;
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      await tester.pump();
      await tester.pump();
      expect(find.text('alice'), findsNothing);
      expect(key('quota-entry-USER-1000'), findsNothing);
      pending.complete(const []);
      await tester.pumpAndSettle();
      expect(find.text('No datasets returned'), findsOneWidget);
    },
  );

  testWidgets(
    'failed reads hide remote details and never retry automatically',
    (tester) async {
      final h = QuotaHarness();
      h.api.datasetError = StateError('private quota trace');
      await pump(tester, harness: h);
      expect(find.text('Could not load datasets'), findsOneWidget);
      expect(find.textContaining('private quota trace'), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(h.api.datasetReads, 1);
      h.api.datasetError = null;
      await tap(tester, 'quota-retry');
      expect(h.api.datasetReads, 2);
      expect(find.text('alice'), findsOneWidget);
    },
  );

  for (final kind in ['USER', 'GROUP']) {
    testWidgets(
      '320px at 200 percent supports $kind lookup limits and exact review',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = await pump(tester, scale: 2);
        await edit(tester, kind: kind, id: kind == 'USER' ? 1000 : 2000);
        await tap(tester, 'quota-identity-resolve');
        await mode(tester, 'objects', 'Set a limit');
        await reveal(tester, key('quota-object-limit'));
        await tester.enterText(key('quota-object-limit'), '300');
        await tap(tester, 'quota-review');
        await reveal(tester, key('quota-confirm-text'));
        expect(tester.takeException(), isNull);
        await tap(tester, 'quota-confirm-cancel');
        expect(h.api.executions, 0);
      },
    );
  }

  test('constant-compatible preview supplies synthetic data and rejects every write path', () async {
    const preview = _Preview();
    final datasets = await preview.loadQuotaDatasets();
    final inventory = await preview.loadQuotas(datasets.first);
    final identity = await preview.resolveQuotaIdentity(
      inventory,
      QuotaKind.user,
      1000,
    );
    expect(inventory.entries.any((entry) => entry.usedBytes == null), true);
    await expectLater(
      preview.reviewQuotaChange(
        QuotaChange(inventory: inventory, identity: identity, byteLimit: 1024),
      ),
      throwsA(isA<QuotaException>()),
    );
    final review = QuotaReview(
      dataset: datasets.first,
      identity: identity,
      confirmation: '${datasets.first.id} USER 1000',
      changes: const [],
      warnings: const [],
    );
    expect(
      (await preview.executeQuotaReview(review, review.confirmation)).outcome,
      QuotaOutcome.rejected,
    );
  });
}

class _Preview with QuotasPreviewAdapter {
  const _Preview();
}
