import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/snapshots/snapshots_page.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'snapshot_fakes.dart';

void main() {
  testWidgets(
    'inventory uses compact binary sizes and UTC dates while details retain exact values',
    (tester) async {
      final api = SnapshotFake();
      final original = api.entry;
      api.entry = SnapshotEntry(
        id: original.id,
        dataset: original.dataset,
        name: original.name,
        guid: original.guid,
        creationSeconds:
            DateTime.utc(2026, 9, 12, 2, 5, 37).millisecondsSinceEpoch ~/ 1000,
        creationTxg: original.creationTxg,
        usedBytes: 41943040,
        referencedBytes: 17179869184,
        holds: {},
        userReferences: 0,
        clones: [],
        deferredDestroy: false,
      );
      await _pump(tester, api: api);
      expect(find.text('Used 40 MiB · referenced 16 GiB'), findsOneWidget);
      expect(find.text('Created 2026-09-12 02:05 UTC'), findsOneWidget);
      await _tap(tester, 'View snapshot');
      expect(find.text('Used: 41943040 bytes'), findsOneWidget);
      expect(find.text('Referenced: 17179869184 bytes'), findsOneWidget);
      expect(find.text('Created: 2026-09-12T02:05:37.000Z'), findsOneWidget);
      expect(
        find.text('Creation time: ${api.entry.creationSeconds} Unix seconds'),
        findsOneWidget,
      );
      expect(find.text('GUID: ${original.guid}'), findsOneWidget);
      expect(api.creates, isEmpty);
      expect(api.deletes, isEmpty);
    },
  );
  testWidgets(
    'pending refresh disables selection until its bounded read completes',
    (tester) async {
      final h = await _pump(tester);
      final pending = Completer<void>();
      h.api.beforeRead = () => pending.future;
      await _visible(tester, find.text('Refresh snapshots'));
      await tester.tap(find.text('Refresh snapshots'));
      await tester.pump();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .onChanged,
        isNull,
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Search'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create snapshot'),
            )
            .onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(h.api.queries.length, 2);
      expect(h.api.creates, isEmpty);
    },
  );
  testWidgets('snapshot entry performs bounded reads and no writes', (
    tester,
  ) async {
    final h = await _pump(tester);
    expect(h.api.datasetReads, 1);
    expect(h.api.queries, [const SnapshotQuery(dataset: 'tank/data')]);
    expect(h.api.creates, isEmpty);
    expect(h.api.deletes, isEmpty);
    expect(find.text('manual-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('prefix search reloads the exact selected filesystem', (
    tester,
  ) async {
    final h = await _pump(tester);
    await tester.enterText(find.byType(TextField), 'absent-');
    await _tap(tester, 'Search');
    expect(h.api.queries.last.namePrefix, 'absent-');
    expect(h.api.queries.last.dataset, 'tank/data');
    expect(
      find.text('No snapshots match this filesystem and prefix.'),
      findsOneWidget,
    );
    expect(h.api.creates, isEmpty);
    expect(h.api.deletes, isEmpty);
  });
  testWidgets(
    'read-only account shows history with create and delete disabled',
    (tester) async {
      final api = SnapshotFake()..writable = false;
      final h = await _pump(tester, api: api);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create snapshot'),
            )
            .onPressed,
        isNull,
      );
      await _tap(tester, 'View snapshot');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Permanently delete snapshot'),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.deletes, isEmpty);
    },
  );
  testWidgets(
    'create requires review and uses one explicit filesystem request',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, 'Create snapshot');
      await tester.enterText(find.byType(TextField), 'manual-new');
      expect(h.api.creates, isEmpty);
      await _tap(tester, 'Review creation');
      expect(find.text('Snapshot: tank/data@manual-new'), findsOneWidget);
      expect(h.api.creates, isEmpty);
      await _tap(tester, 'Create this snapshot');
      expect(h.api.creates.single.dataset, same(h.api.dataset));
      expect(h.api.creates.single.name, 'manual-new');
      expect(h.api.deletes, isEmpty);
    },
  );
  testWidgets(
    'details expose exact size identity and enforce full typed deletion',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, 'View snapshot');
      expect(find.text('GUID: 18446744073709551615'), findsOneWidget);
      expect(find.text('Used: 1024 bytes'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'manual-1');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Permanently delete snapshot'),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.deletes, isEmpty);
      await tester.enterText(find.byType(TextField), h.api.entry.id);
      await _tap(tester, 'Permanently delete snapshot');
      expect(h.api.deletes.single.snapshot, same(h.api.entry));
      expect(h.api.deletes.single.confirmation, h.api.entry.id);
    },
  );
  testWidgets('changing session while reviewing disables mutation', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'Create snapshot');
    await tester.enterText(find.byType(TextField), 'manual-new');
    await _tap(tester, 'Review creation');
    h.select(snapshotSession(h.api));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create this snapshot'),
          )
          .onPressed,
      isNull,
    );
    expect(h.api.creates, isEmpty);
  });
  testWidgets('held clone snapshot details keep deletion disabled', (
    tester,
  ) async {
    final api = SnapshotFake();
    api.entry = SnapshotEntry(
      id: api.entry.id,
      dataset: api.entry.dataset,
      name: api.entry.name,
      guid: '999',
      creationSeconds: 1720000000,
      creationTxg: '43210',
      usedBytes: 1024,
      referencedBytes: 536870912,
      holds: {'truenas': 1720000001},
      userReferences: 1,
      clones: ['tank/clone'],
      deferredDestroy: false,
      blockedReason: 'This snapshot has holds and cannot be deleted here.',
    );
    await _pump(tester, api: api);
    await _tap(tester, 'View snapshot');
    expect(find.text('tank/clone'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(api.deletes, isEmpty);
  });
  for (final destination in ['inventory', 'create', 'details']) {
    testWidgets('$destination fits 320px at 200% text scale', (tester) async {
      final h = await _pump(tester, narrow: true);
      if (destination == 'create') {
        await _tap(tester, 'Create snapshot');
        await tester.enterText(find.byType(TextField), 'manual-new');
        await _tap(tester, 'Review creation');
        await _visible(tester, find.text('Create this snapshot'));
      } else if (destination == 'details') {
        await _tap(tester, 'View snapshot');
        await _visible(tester, find.text('Permanently delete snapshot'));
      } else {
        await _visible(tester, find.text('Select for exact deletion'));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(h.api.creates, isEmpty);
      expect(h.api.deletes, isEmpty);
    });
  }
}

Future<SnapshotHarness> _pump(
  WidgetTester tester, {
  SnapshotFake? api,
  bool narrow = false,
}) async {
  final h = SnapshotHarness(repository: api);
  addTearDown(h.dispose);
  if (narrow) {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueRAIDTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
          child: child!,
        ),
        home: const SnapshotsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await _visible(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _visible(WidgetTester tester, Finder target) async {
  await tester.pumpAndSettle();
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 40,
    );
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pumpAndSettle();
}
