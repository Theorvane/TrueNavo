import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/dev/replication_preview.dart';
import 'package:truenavo/features/replication/replication_controller.dart';
import 'package:truenavo/features/replication/replication_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'replication_fakes.dart';

class _Preview with ReplicationPreviewAdapter {
  const _Preview();
}

Future<ReplicationHarness> pumpReplication(
  WidgetTester tester, {
  ReplicationFake? fake,
  double width = 800,
  double scale = 1,
  bool light = false,
  bool disconnected = false,
  bool load = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = ReplicationHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) h.select(null);
  if (!disconnected && load) {
    await h.container.read(replicationInventoryProvider.future);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: light ? TrueNavoTheme.light() : TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const ReplicationPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapReplication(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> fillReplication(
  WidgetTester tester,
  String key,
  String value,
) async {
  final finder = find.byKey(Key(key));
  await reveal(tester, finder);
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> confirmReplication(WidgetTester tester, String target) async {
  await fillReplication(tester, 'replication-confirm-target', target);
  await tapReplication(tester, 'replication-confirm-impact');
  await tapReplication(tester, 'replication-confirm-submit');
}

void main() {
  for (final missing in [true, false]) {
    testWidgets(
      'editing a ${missing ? 'missing' : 'blocked'} source requires an explicit new choice without crashing',
      (tester) async {
        final initial = replicationInventory();
        final data = ReplicationInventory(
          endpoint: replicationEndpoint,
          tasks: initial.tasks,
          datasets: [
            for (final dataset in initial.datasets)
              if (dataset.id != 'tank/source') dataset,
            if (!missing)
              const ReplicationDataset(
                id: 'tank/source',
                guid: '101',
                readonly: false,
                blockedReason: 'Source is locked.',
              ),
          ],
        );
        final h = await pumpReplication(
          tester,
          fake: ReplicationFake(inventory: data),
        );
        await tapReplication(tester, 'replication-update-1');
        expect(
          find.textContaining('original source is unavailable'),
          findsOneWidget,
        );
        expect(find.text('Choose a source'), findsOneWidget);
        await tapReplication(tester, 'replication-editor-review');
        expect(h.api.reviews, isEmpty);
        expect(h.api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('missing mutation methods provide disabled-action explanation', (
    tester,
  ) async {
    final h = await pumpReplication(
      tester,
      fake: ReplicationFake(
        caps: const ReplicationCapabilities(
          connected: true,
          versionSupported: true,
          available: true,
          canCreate: false,
          canUpdate: false,
          canDelete: false,
          canRun: false,
        ),
      ),
    );
    expect(
      find.textContaining('required public methods or permissions are missing'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('replication-create')))
          .onPressed,
      isNull,
    );
    for (final action in ['update', 'disable', 'run', 'delete']) {
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(Key('replication-$action-1')))
            .onPressed,
        isNull,
      );
    }
    expect(h.api.writes, isEmpty);
  });
  testWidgets('opening and refresh read counts only, never dispatch or poll', (
    tester,
  ) async {
    final h = await pumpReplication(tester);
    expect(
      find.byKey(const Key('replication-enablement-donut')),
      findsOneWidget,
    );
    expect(find.text('1 enabled · 1 disabled'), findsOneWidget);
    final colors = Theme.of(tester.element(find.byType(ReplicationSummary)))
        .colorScheme;
    expect(
      (tester
                  .widget<DecoratedBox>(
                    find.byKey(const Key('replication-enabled-swatch')),
                  )
                  .decoration
              as BoxDecoration)
          .color,
      colors.primary,
    );
    expect(
      (tester
                  .widget<DecoratedBox>(
                    find.byKey(const Key('replication-disabled-swatch')),
                  )
                  .decoration
              as BoxDecoration)
          .color,
      colors.surfaceContainerHighest,
    );
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('1 native-editable · 1 advanced'), findsOneWidget);
    expect(find.text('FINISHED: 1'), findsOneWidget);
    await tapReplication(tester, 'replication-refresh');
    expect(h.api.reads, 2);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
    expect(h.api.polls, isEmpty);
  });
  testWidgets('unsupported tasks stay visible with every action disabled', (
    tester,
  ) async {
    final h = await pumpReplication(tester);
    for (final key in [
      'replication-update-2',
      'replication-enable-2',
      'replication-run-2',
      'replication-delete-2',
    ]) {
      expect(
        tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
        isNull,
      );
    }
    expect(
      find.text('Remote tasks require the advanced TrueNAS workflow.'),
      findsOneWidget,
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets('run requires exact typed target and separate impact checkbox', (
    tester,
  ) async {
    final h = await pumpReplication(tester);
    await tapReplication(tester, 'replication-run-1');
    expect(find.text('RUN Archive'), findsOneWidget);
    expect(
      find.widgetWithText(SelectableText, replicationEndpoint),
      findsOneWidget,
    );
    expect(
      find.textContaining('roll back destination changes'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Source snapshots (total): 4 · Destination snapshots (total): 2',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Totals are not eligible transfer or deletion counts.'),
      findsOneWidget,
    );
    expect(h.api.writes, isEmpty);
    await fillReplication(tester, 'replication-confirm-target', 'RUN Archive ');
    await tapReplication(tester, 'replication-confirm-impact');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('replication-confirm-submit')),
          )
          .onPressed,
      isNull,
    );
    await fillReplication(tester, 'replication-confirm-target', 'RUN Archive');
    await tapReplication(tester, 'replication-confirm-submit');
    expect(h.api.writes.single.action, ReplicationAction.run);
    expect(h.api.polls, isEmpty);
  });
  testWidgets('cancel run delete and toggle reviews never writes', (
    tester,
  ) async {
    final h = await pumpReplication(tester);
    for (final action in ['run', 'delete', 'disable']) {
      await tapReplication(tester, 'replication-$action-1');
      await tapReplication(tester, 'replication-confirm-cancel');
    }
    expect(h.api.reviews.length, 3);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('delete review distinguishes task configuration from data', (
    tester,
  ) async {
    final h = await pumpReplication(tester);
    await tapReplication(tester, 'replication-delete-1');
    expect(find.textContaining('not its existing snapshots'), findsOneWidget);
    await confirmReplication(tester, 'DELETE Archive');
    expect(h.api.writes.single.action, ReplicationAction.delete);
  });
  testWidgets(
    'create does not preselect source or destination and validates blank form',
    (tester) async {
      final h = await pumpReplication(tester);
      await tapReplication(tester, 'replication-create');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('replication-name')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('replication-destination')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('Choose a source'), findsOneWidget);
      await tapReplication(tester, 'replication-editor-review');
      expect(find.textContaining('Use a task name'), findsOneWidget);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
      await tapReplication(tester, 'replication-editor-cancel');
    },
  );
  testWidgets(
    'create prepares safe local settings then requires a separate review',
    (tester) async {
      final h = await pumpReplication(tester);
      await tapReplication(tester, 'replication-create');
      await fillReplication(tester, 'replication-name', 'New archive');
      await tapReplication(tester, 'replication-source');
      await tester.tap(find.text('tank/source').last);
      await tester.pumpAndSettle();
      await fillReplication(
        tester,
        'replication-destination',
        'backup/parent/new',
      );
      await tapReplication(tester, 'replication-editor-review');
      expect(h.api.reviews.length, 1);
      expect(h.api.writes, isEmpty);
      final settings = h.api.reviews.single.settings!;
      expect(settings.source, 'tank/source');
      expect(settings.destination, 'backup/parent/new');
      expect(settings.retention, 'NONE');
      expect(settings.enabled, isTrue);
      expect(
        find.textContaining('does not start a replication run'),
        findsOneWidget,
      );
      await confirmReplication(tester, 'CREATE New archive');
      expect(h.api.writes.single.action, ReplicationAction.create);
    },
  );
  testWidgets(
    'edit preserves existing settings, custom lifetime and enabled choice',
    (tester) async {
      final h = await pumpReplication(tester);
      await tapReplication(tester, 'replication-update-1');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('replication-name')))
            .controller!
            .text,
        'Archive',
      );
      await tapReplication(tester, 'replication-retention');
      await tester.tap(find.text('CUSTOM · Lifetime').last);
      await tester.pumpAndSettle();
      await fillReplication(tester, 'replication-lifetime', '9');
      await tapReplication(tester, 'replication-enabled');
      await tapReplication(tester, 'replication-editor-review');
      expect(h.api.reviews.single.settings!.retention, 'CUSTOM');
      expect(h.api.reviews.single.settings!.lifetimeValue, 9);
      expect(h.api.reviews.single.settings!.enabled, isFalse);
      expect(h.api.writes, isEmpty);
      await confirmReplication(tester, 'UPDATE Archive');
      expect(h.api.writes.single.action, ReplicationAction.update);
    },
  );
  testWidgets(
    'overlapping destination and invalid lifetime never reach review',
    (tester) async {
      final h = await pumpReplication(tester);
      await tapReplication(tester, 'replication-update-1');
      await fillReplication(
        tester,
        'replication-destination',
        'tank/source/child',
      );
      await tapReplication(tester, 'replication-editor-review');
      expect(find.textContaining('distinct, unrelated'), findsOneWidget);
      await fillReplication(
        tester,
        'replication-destination',
        'backup/archive',
      );
      await tapReplication(tester, 'replication-retention');
      await tester.tap(find.text('CUSTOM · Lifetime').last);
      await tester.pumpAndSettle();
      await fillReplication(tester, 'replication-lifetime', '0');
      await tapReplication(tester, 'replication-editor-review');
      expect(find.textContaining('1–3650 units'), findsOneWidget);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'connection replacement permanently expires open review and hides old details',
    (tester) async {
      final h = await pumpReplication(tester);
      await tapReplication(tester, 'replication-run-1');
      await fillReplication(
        tester,
        'replication-confirm-target',
        'RUN Archive',
      );
      h.select(h.newSession());
      await tester.pumpAndSettle();
      expect(find.text('Review is no longer current'), findsOneWidget);
      expect(find.text('RUN Archive'), findsNothing);
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('replication-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await tapReplication(tester, 'replication-confirm-cancel');
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'inventory refresh expires editor permanently without exposing old inputs',
    (tester) async {
      final h = await pumpReplication(tester);
      await tapReplication(tester, 'replication-update-1');
      h.container.invalidate(replicationInventoryProvider);
      await tester.pumpAndSettle();
      expect(find.text('Editor is no longer current'), findsOneWidget);
      expect(find.byKey(const Key('replication-name')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('replication-editor-review')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('late review after connection replacement is discarded', (
    tester,
  ) async {
    final h = await pumpReplication(tester);
    final reply = Completer<ReplicationReview>();
    h.api.onReview = (_) => reply.future;
    await tapReplication(tester, 'replication-run-1');
    final request = h.api.reviews.single;
    h.select(h.newSession());
    await tester.pumpAndSettle();
    reply.complete(
      ReplicationReview(
        request: request,
        endpoint: replicationEndpoint,
        warnings: const [],
        sourceSnapshots: 4,
        destinationSnapshots: 2,
        createsDestination: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('replication-confirm-submit')), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('read and review errors withhold all remote details', (
    tester,
  ) async {
    final fake = ReplicationFake();
    fake.onLoad = () => Future.error(StateError('super-secret'));
    final h = await pumpReplication(tester, fake: fake, load: false);
    expect(find.textContaining('super-secret'), findsNothing);
    expect(find.text('Replication information unavailable'), findsOneWidget);
    expect(fake.reads, 1);
    fake.onLoad = null;
    await tapReplication(tester, 'replication-retry');
    fake.onReview = (_) => Future.error(StateError('super-secret'));
    await tapReplication(tester, 'replication-run-1');
    expect(find.textContaining('super-secret'), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('conflicting job disables all mutations', (tester) async {
    final h = await pumpReplication(
      tester,
      fake: ReplicationFake(
        inventory: replicationInventory(conflictingJob: true),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('replication-create')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('replication-run-1')))
          .onPressed,
      isNull,
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets('disconnected page never reads inventory', (tester) async {
    final h = await pumpReplication(tester, disconnected: true);
    expect(find.text('Replication unavailable'), findsOneWidget);
    expect(h.api.reads, 0);
  });
  testWidgets(
    'empty inventory renders an empty donut and no automatic task selection',
    (tester) async {
      final h = await pumpReplication(
        tester,
        fake: ReplicationFake(inventory: replicationInventory(empty: true)),
      );
      expect(find.text('0 enabled · 0 disabled'), findsOneWidget);
      expect(find.text('No replication tasks'), findsOneWidget);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('pending job has manually requested progress only', (
    tester,
  ) async {
    final h = await pumpReplication(tester);
    h.api.onExecute = () async => const ReplicationResult(
      ReplicationOutcome.pending,
      'Queued',
      job: replicationJob,
      percent: 25,
    );
    await tapReplication(tester, 'replication-run-1');
    await confirmReplication(tester, 'RUN Archive');
    expect(find.text('Server-reported job progress: 25.0%'), findsOneWidget);
    expect(h.api.polls, isEmpty);
    await tester.pump(const Duration(minutes: 3));
    expect(h.api.polls, isEmpty);
    await tapReplication(tester, 'replication-poll');
    expect(h.api.polls.single, same(replicationJob));
    expect(h.api.writes.length, 1);
  });
  for (final width in [320.0, 430.0]) {
    for (final light in [false, true]) {
      testWidgets(
        '${width}px 200% ${light ? 'light' : 'dark'} editor and exact review remain usable with keyboard',
        (tester) async {
          final h = await pumpReplication(
            tester,
            width: width,
            scale: 2,
            light: light,
          );
          await tapReplication(tester, 'replication-update-1');
          tester.view.viewInsets = const FakeViewPadding(bottom: 350);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          await fillReplication(
            tester,
            'replication-schema',
            'auto-%Y-%m-%d_%H-%M',
          );
          await tapReplication(tester, 'replication-editor-review');
          await confirmReplication(tester, 'UPDATE Archive');
          expect(h.api.writes.length, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  test('preview fixtures are immutable and cannot submit or poll', () async {
    const preview = _Preview();
    final inventory = await preview.loadReplication();
    expect(() => inventory.tasks.clear(), throwsUnsupportedError);
    expect(() => inventory.datasets.clear(), throwsUnsupportedError);
    expect(
      inventory.datasets.any((d) => d.available && !d.id.contains('/')),
      isFalse,
    );
    expect(inventory.tasks.where((task) => !task.available), isNotEmpty);
    final request = ReplicationRequest(
      inventory: inventory,
      action: ReplicationAction.run,
      task: inventory.tasks.first,
    );
    final review = await preview.reviewReplication(request);
    expect(
      (await preview.executeReplication(review, review.target)).outcome,
      ReplicationOutcome.rejected,
    );
    expect(
      (await preview.pollReplication(replicationJob)).outcome,
      ReplicationOutcome.rejected,
    );
    await expectLater(
      preview.reviewReplication(
        ReplicationRequest(
          inventory: replicationInventory(),
          action: ReplicationAction.run,
          task: replicationTask,
        ),
      ),
      throwsA(isA<ReplicationException>()),
    );
  });
}
