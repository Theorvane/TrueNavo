import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/rsync/rsync_controller.dart';
import 'package:truenavo/features/rsync/rsync_editor.dart';
import 'package:truenavo/features/rsync/rsync_page.dart';
import 'package:truenavo/features/rsync/rsync_review.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'rsync_fakes.dart';

Future<RsHarness> pumpRs(
  WidgetTester tester, {
  RsFake? fake,
  bool disconnected = false,
  double width = 800,
  double scale = 1,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = RsHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.container.read(rsyncInventoryProvider.future);
    } on Object {
      /* Fixed error UI. */
    }
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const RsyncPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapRs(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> enterRs(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> confirmRs(
  WidgetTester tester,
  String target, {
  bool settle = true,
}) async {
  await enterRs(tester, 'rsync-confirm-target', target);
  await tapRs(tester, 'rsync-confirm-impact');
  await tapRs(tester, 'rsync-confirm-submit', settle: settle);
}

void expectActionDisabled(WidgetTester tester, String key) => expect(
  tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
  isNull,
);

void backgroundAndResume(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets('opening and manual refresh are read only with no polling', (
    tester,
  ) async {
    final h = await pumpRs(tester);
    expect(find.text('0 Enabled tasks'), findsOneWidget);
    expect(find.text('1 Disabled tasks'), findsOneWidget);
    expect(
      find.text('Last recorded job states (may be stale)'),
      findsOneWidget,
    );
    expect(find.text('Dataset locked: No'), findsOneWidget);
    await tester.pump(const Duration(minutes: 5));
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
    expect(h.api.checks, isEmpty);
    await tapRs(tester, 'rsync-refresh');
    expect(h.api.reads, 2);
  });
  testWidgets('disconnected does not read', (tester) async {
    final h = await pumpRs(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('Rsync unavailable'), findsOneWidget);
  });
  testWidgets('wrong-endpoint inventory never exposes task or SSH details', (
    tester,
  ) async {
    final h = await pumpRs(
      tester,
      fake: RsFake(
        inventory: rsInventory(endpoint: 'wss://other.example/api/current'),
      ),
    );
    expect(find.text('Rsync inventory unavailable'), findsOneWidget);
    expect(find.text('Task 11'), findsNothing);
    expect(find.textContaining('/mnt/tank/media'), findsNothing);
    expect(find.textContaining('backup.example'), findsNothing);
    expect(find.text('wss://other.example/api/current'), findsNothing);
    expect(h.container.read(rsyncInventoryProvider).hasError, isTrue);
    expect(h.api.writes, isEmpty);
    expect(h.api.checks, isEmpty);
  });
  testWidgets(
    'late inventory after session replacement cannot overwrite current server',
    (tester) async {
      final h = await pumpRs(tester);
      final pending = Completer<RsyncInventory>();
      final original = h.api.inventory;
      h.api.onLoad = () => pending.future;
      await tapRs(tester, 'rsync-refresh', settle: false);
      final current = rsInventory(
        endpoint: 'wss://other.example/api/current',
        empty: true,
      );
      h.api.onLoad = () async => current;
      h.select(h.newSession(endpoint: current.endpoint));
      await tester.pumpAndSettle();
      expect(find.text('No Rsync tasks'), findsOneWidget);
      pending.complete(original);
      await tester.pumpAndSettle();
      expect(
        h.container.read(rsyncInventoryProvider).asData?.value,
        same(current),
      );
      expect(find.text('Task 11'), findsNothing);
      expect(find.textContaining('/mnt/tank/media'), findsNothing);
      expect(find.textContaining('backup.example'), findsNothing);
      expect(h.api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('empty is distinct from unknown', (tester) async {
    await pumpRs(tester, fake: RsFake(inventory: rsInventory(empty: true)));
    expect(find.text('No Rsync tasks'), findsOneWidget);
    expect(find.text('0 Enabled tasks'), findsOneWidget);
  });
  testWidgets('read failure redacts details and never retries automatically', (
    tester,
  ) async {
    final h = await pumpRs(
      tester,
      fake: RsFake()..onLoad = () async => throw StateError('PRIVATE-FIXTURE'),
    );
    expect(find.text('Rsync inventory unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE-FIXTURE'), findsNothing);
    expect(find.text('0 Enabled tasks'), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(h.api.reads, 1);
    await tapRs(tester, 'rsync-retry');
    expect(h.api.reads, 2);
    expect(h.api.writes, isEmpty);
  });
  for (final guard in ['HA', 'job', 'locked', 'unsupported']) {
    testWidgets('$guard forbids task actions', (tester) async {
      final h = await pumpRs(
        tester,
        fake: RsFake(
          inventory: rsInventory(
            ha: guard == 'HA',
            jobs: guard == 'job',
            locked: guard == 'locked',
            unsupported: guard == 'unsupported',
          ),
        ),
      );
      for (final action in ['update', 'enable', 'delete', 'run']) {
        expectActionDisabled(tester, 'rsync-$action-11');
      }
      if (guard == 'locked') {
        expect(find.text('Dataset locked: Yes'), findsOneWidget);
      }
      if (guard == 'unsupported') {
        expect(find.textContaining('Local dataset:'), findsNothing);
      }
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('enabled task permits only disable not edit run delete', (
    tester,
  ) async {
    await pumpRs(tester, fake: RsFake(inventory: rsInventory(enabled: true)));
    for (final action in ['update', 'delete', 'run']) {
      expectActionDisabled(tester, 'rsync-$action-11');
    }
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('rsync-disable-11')))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('nullable recorded state stays unknown', (tester) async {
    await pumpRs(tester, fake: RsFake(inventory: rsInventory(lastState: null)));
    expect(find.byKey(const Key('rsync-state-unknown')), findsOneWidget);
    expect(find.byKey(const Key('rsync-state-succeeded')), findsNothing);
  });
  for (final action in [
    RsyncAction.enable,
    RsyncAction.disable,
    RsyncAction.delete,
    RsyncAction.run,
  ]) {
    testWidgets('review $action exact target plus impact sends once only', (
      tester,
    ) async {
      final h = await pumpRs(
        tester,
        fake: RsFake(
          inventory: rsInventory(enabled: action == RsyncAction.disable),
        ),
      );
      await tapRs(tester, 'rsync-${action.name}-11');
      final review = h.api.reviews.single;
      expect(find.byType(RsyncReviewDialog), findsOneWidget);
      expect(h.api.writes, isEmpty);
      expect(find.text('Before'), findsOneWidget);
      expect(
        find.textContaining('Destination files may be overwritten'),
        findsWidgets,
      );
      expect(
        find.textContaining(
          'an absent destination may produce a different layout',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Remote existence and layout are not verified'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('rsync-confirm-submit')))
            .onPressed,
        isNull,
      );
      await enterRs(tester, 'rsync-confirm-target', '${review.target} ');
      await tapRs(tester, 'rsync-confirm-impact');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('rsync-confirm-submit')))
            .onPressed,
        isNull,
      );
      await enterRs(tester, 'rsync-confirm-target', review.target);
      await tapRs(tester, 'rsync-confirm-submit');
      expect(h.api.writes, hasLength(1));
      expect(h.api.writes.single.action, action);
    });
  }
  testWidgets(
    'edit before/after preserves exact source path and safe options',
    (tester) async {
      final h = await pumpRs(tester);
      await tapRs(tester, 'rsync-update-11');
      expect(find.byType(RsyncEditor), findsOneWidget);
      expect(
        find.textContaining(
          'If the destination is absent, the resulting layout may differ',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('rsync-remote-path')))
            .maxLength,
        255,
      );
      await enterRs(tester, 'rsync-description', 'Changed copy');
      await tapRs(tester, 'rsync-editor-review');
      final request = h.api.reviews.single;
      expect(request.settings!.path, '/mnt/tank/media');
      expect(request.settings!.enabled, isFalse);
      expect(find.text('Before'), findsOneWidget);
      expect(find.text('After'), findsOneWidget);
      expect(find.text('Description: Media copy'), findsOneWidget);
      expect(find.text('Description: Changed copy'), findsOneWidget);
      expect(find.textContaining('Public key fingerprint:'), findsOneWidget);
      await confirmRs(tester, request.target);
      expect(h.api.writes, hasLength(1));
    },
  );
  testWidgets(
    'create requires explicit selections, valid remote path and remains disabled',
    (tester) async {
      final h = await pumpRs(tester);
      await tapRs(tester, 'rsync-create');
      await tapRs(tester, 'rsync-editor-review');
      expect(h.api.reviews, isEmpty);
      for (final entry in [
        ('dataset', '/mnt/tank/media'),
        ('user', 'backup · UID 1001'),
        ('connection', 'Backup SSH · replica@backup.example:22'),
      ]) {
        await tapRs(tester, 'rsync-${entry.$1}');
        await tester.tap(find.text(entry.$2).last);
        await tester.pumpAndSettle();
      }
      await enterRs(tester, 'rsync-remote-path', '/srv/backup');
      await tapRs(tester, 'rsync-editor-review');
      expect(h.api.reviews.single.action, RsyncAction.create);
      expect(h.api.reviews.single.settings!.enabled, isFalse);
      expect(h.api.writes, isEmpty);
    },
  );
  for (final form in ['editor', 'review']) {
    for (final cause in ['session', 'inventory', 'background']) {
      testWidgets('$form expires and hides details on $cause', (tester) async {
        final h = await pumpRs(tester);
        await tapRs(
          tester,
          form == 'editor' ? 'rsync-update-11' : 'rsync-run-11',
        );
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'inventory') {
          h.api.inventory = rsInventory();
          h.container.invalidate(rsyncInventoryProvider);
        }
        if (cause == 'background') {
          backgroundAndResume(tester);
        }
        await tester.pumpAndSettle();
        expect(
          find.text(
            form == 'editor' ? 'Rsync editor expired' : 'Review expired',
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(form == 'editor' ? RsyncEditor : RsyncReviewDialog),
            matching: find.textContaining('/mnt/tank/media'),
          ),
          findsNothing,
        );
        expect(h.api.writes, isEmpty);
      });
    }
  }
  for (final cause in ['session', 'background', 'dispose']) {
    testWidgets('late review response after $cause never opens confirmation', (
      tester,
    ) async {
      final pending = Completer<RsyncReview>();
      final h = await pumpRs(
        tester,
        fake: RsFake()..onReview = (_) => pending.future,
      );
      await tapRs(tester, 'rsync-run-11');
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'background') {
        backgroundAndResume(tester);
      }
      if (cause == 'dispose') await tester.pumpWidget(const SizedBox());
      pending.complete(
        RsyncReview(
          request: h.api.reviews.single,
          endpoint: rsEndpoint,
          warnings: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RsyncReviewDialog), findsNothing);
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('accepted job locks every action until explicit check', (
    tester,
  ) async {
    final fake = RsFake();
    fake.onExecute = (_) async =>
        RsyncResult(RsyncOutcome.accepted, 'Queued', job: rsJob());
    final h = await pumpRs(tester, fake: fake);
    await tapRs(tester, 'rsync-run-11');
    await confirmRs(tester, h.api.reviews.single.target);
    expect(find.text('Job 80 · Run transfer once · Task 11'), findsOneWidget);
    for (final action in ['update', 'enable', 'delete', 'run']) {
      expectActionDisabled(tester, 'rsync-$action-11');
    }
    await tester.pump(const Duration(minutes: 5));
    expect(h.api.checks, isEmpty);
    await tapRs(tester, 'rsync-check-job');
    expect(h.api.checks, hasLength(1));
    expect(h.api.writes, hasLength(1));
    expect(h.container.read(rsyncControllerProvider).locked, isFalse);
  });
  testWidgets('unknown outcome locks retries and hides raw errors', (
    tester,
  ) async {
    final h = await pumpRs(
      tester,
      fake: RsFake()
        ..onExecute = (_) async => throw StateError('PRIVATE-FIXTURE'),
    );
    await tapRs(tester, 'rsync-run-11');
    await confirmRs(tester, h.api.reviews.single.target);
    expect(find.text('Verify before continuing'), findsOneWidget);
    expect(find.textContaining('PRIVATE-FIXTURE'), findsNothing);
    expectActionDisabled(tester, 'rsync-run-11');
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('rsync-refresh')))
          .onPressed,
      isNull,
    );
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    await tester.pumpAndSettle();
    expect(find.text('Original operation needs attention'), findsOneWidget);
    expect(find.textContaining('Local dataset:'), findsNothing);
  });
  testWidgets(
    'legacy task needs fixed filesystem protection before run or enable',
    (tester) async {
      final h = await pumpRs(
        tester,
        fake: RsFake(inventory: rsInventory(crossFilesystemProtection: false)),
      );
      expectActionDisabled(tester, 'rsync-run-11');
      expectActionDisabled(tester, 'rsync-enable-11');
      await tapRs(tester, 'rsync-update-11');
      await tapRs(tester, 'rsync-editor-review');
      expect(
        find.text('Cross-filesystem protection: Not configured'),
        findsOneWidget,
      );
      expect(
        find.text('After: fixed --one-file-system protection configured.'),
        findsOneWidget,
      );
      expect(h.api.reviews.single.action, RsyncAction.update);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('mismatching review identity is redacted and never confirmed', (
    tester,
  ) async {
    final fake = RsFake();
    fake.onReview = (request) async => RsyncReview(
      request: request,
      endpoint: 'wss://other.example/api/current',
      warnings: ['PRIVATE-FIXTURE'],
    );
    final h = await pumpRs(tester, fake: fake);
    await tapRs(tester, 'rsync-run-11');
    expect(find.byType(RsyncReviewDialog), findsNothing);
    expect(find.textContaining('PRIVATE-FIXTURE'), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'editor to asynchronous review background gap discards the draft',
    (tester) async {
      final pending = Completer<RsyncReview>();
      final h = await pumpRs(
        tester,
        fake: RsFake()..onReview = (_) => pending.future,
      );
      await tapRs(tester, 'rsync-update-11');
      await enterRs(tester, 'rsync-description', 'Gap fixture');
      await tapRs(tester, 'rsync-editor-review');
      backgroundAndResume(tester);
      pending.complete(
        RsyncReview(
          request: h.api.reviews.single,
          endpoint: rsEndpoint,
          warnings: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RsyncReviewDialog), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'create selectors at $width and 200 percent preserve exact choices',
      (tester) async {
        final h = await pumpRs(tester, width: width, scale: 2, keyboard: 300);
        await tapRs(tester, 'rsync-create');
        for (final entry in [
          ('dataset', '/mnt/tank/media'),
          ('user', 'backup · UID 1001'),
          ('connection', 'Backup SSH · replica@backup.example:22'),
        ]) {
          await tapRs(tester, 'rsync-${entry.$1}');
          await tester.tap(find.text(entry.$2).last);
          await tester.pumpAndSettle();
        }
        await enterRs(tester, 'rsync-remote-path', '/srv/backup');
        await tapRs(tester, 'rsync-editor-review');
        expect(h.api.reviews.single.settings!.connectionId, 21);
        expect(h.api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    for (final form in ['page', 'editor', 'review']) {
      testWidgets(
        '$form at $width and 200 percent with keyboard has no overflow',
        (tester) async {
          final h = await pumpRs(
            tester,
            width: width,
            scale: 2,
            keyboard: form == 'page' ? 0 : 300,
          );
          if (form == 'editor') {
            await tapRs(tester, 'rsync-update-11');
            await enterRs(tester, 'rsync-description', 'Narrow screen');
            await tapRs(tester, 'rsync-editor-review');
            expect(find.byType(RsyncReviewDialog), findsOneWidget);
          }
          if (form == 'review') {
            await tapRs(tester, 'rsync-run-11');
            await confirmRs(tester, h.api.reviews.single.target);
            expect(h.api.writes, hasLength(1));
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
