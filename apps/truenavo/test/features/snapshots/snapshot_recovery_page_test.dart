import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/snapshots/snapshot_recovery_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'snapshot_fakes.dart';

void main() {
  for (final kind in [
    SnapshotRecoveryKind.clone,
    SnapshotRecoveryKind.recursiveCreate,
    SnapshotRecoveryKind.hold,
    SnapshotRecoveryKind.release,
    SnapshotRecoveryKind.rollback,
    SnapshotRecoveryKind.bulkDelete,
  ]) {
    testWidgets(
      '${kind.name} exact impact requires selected scope and typed target',
      (tester) async {
        final h = SnapshotHarness();
        addTearDown(h.dispose);
        await _pump(tester, h, kind);
        if (kind == SnapshotRecoveryKind.clone) {
          await _tap(tester, find.byKey(const Key('recovery-clone-parent')));
          await tester.tap(find.text(h.api.dataset.id).last);
          await tester.pumpAndSettle();
        }
        if (kind == SnapshotRecoveryKind.clone ||
            kind == SnapshotRecoveryKind.recursiveCreate) {
          await tester.enterText(
            find.byKey(const Key('recovery-name')),
            'reviewed-new',
          );
          await tester.pump();
        }
        expect(h.api.recoveries, isEmpty);
        await _tap(tester, find.byKey(const Key('recovery-review')));
        expect(h.api.recoveryPlans, hasLength(1));
        expect(h.api.recoveries, isEmpty);
        await _tap(tester, find.byKey(const Key('recovery-authorize-targets')));
        if ({
          SnapshotRecoveryKind.release,
          SnapshotRecoveryKind.rollback,
          SnapshotRecoveryKind.bulkDelete,
        }.contains(kind)) {
          await _tap(
            tester,
            find.byKey(const Key('recovery-acknowledge-loss')),
          );
        }
        final target = h.api.recoveryPlans.single.target;
        await _visible(tester, find.byKey(const Key('recovery-confirmation')));
        await tester.enterText(
          find.byKey(const Key('recovery-confirmation')),
          'WRONG',
        );
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('recovery-apply')))
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byKey(const Key('recovery-confirmation')),
          target,
        );
        await _tap(tester, find.byKey(const Key('recovery-apply')));
        expect(h.api.recoveries, hasLength(1));
        expect(h.api.recoveries.single.confirmation, target);
      },
    );
  }
  testWidgets('read-only recovery page cannot obtain a review or write', (
    tester,
  ) async {
    final h = SnapshotHarness(repository: SnapshotFake()..writable = false);
    addTearDown(h.dispose);
    await _pump(tester, h, SnapshotRecoveryKind.hold);
    expect(
      find.text('This operation is unavailable to this account.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('recovery-review')))
          .onPressed,
      isNull,
    );
    expect(h.api.recoveryPlans, isEmpty);
    expect(h.api.recoveries, isEmpty);
  });
  testWidgets('session replacement hides recovery impact and never writes', (
    tester,
  ) async {
    final h = SnapshotHarness();
    addTearDown(h.dispose);
    await _pump(tester, h, SnapshotRecoveryKind.rollback);
    await _tap(tester, find.byKey(const Key('recovery-review')));
    h.select(null);
    await tester.pumpAndSettle();
    expect(find.text('Connection changed'), findsOneWidget);
    expect(find.textContaining('18446744073709551615'), findsNothing);
    expect(find.byKey(const Key('recovery-apply')), findsNothing);
    expect(h.api.recoveries, isEmpty);
  });
  testWidgets('blocked newer snapshot impact has no apply action', (
    tester,
  ) async {
    final h = SnapshotHarness();
    addTearDown(h.dispose);
    final plan = SnapshotRecoveryPlan.rollback(h.api.entry);
    h.api.recoveryReview = SnapshotRecoveryReview(
      plan: plan,
      snapshots: [h.api.entry],
      datasets: [h.api.dataset],
      newerSnapshots: [h.api.entry],
      warnings: [],
      blockedReason: 'Newer snapshots cannot be implicitly destroyed.',
    );
    await _pump(tester, h, SnapshotRecoveryKind.rollback);
    await _tap(tester, find.byKey(const Key('recovery-review')));
    expect(find.text('Newer snapshots: 1'), findsOneWidget);
    expect(find.byKey(const Key('recovery-apply')), findsNothing);
    expect(h.api.recoveries, isEmpty);
  });
  testWidgets('shared lock rejects recovery and unknown result stays locked', (
    tester,
  ) async {
    final h = SnapshotHarness();
    addTearDown(h.dispose);
    final review = await h.api.reviewSnapshotRecovery(
      SnapshotRecoveryPlan.hold(h.api.entry),
    );
    final request = SnapshotRecoveryRequest(
      review: review,
      confirmation: review.plan.target,
    );
    final owner = h.lock.acquire()!;
    await h.controller.recover(expectedSession: h.session, request: request);
    expect(h.api.recoveries, isEmpty);
    h.lock.release(owner);
    h.api.outcome = SnapshotOperationOutcome.unknown;
    await h.controller.recover(expectedSession: h.session, request: request);
    expect(h.state.unresolved, isTrue);
    expect(h.lock.acquire(), isNull);
    await h.controller.recover(expectedSession: h.session, request: request);
    expect(h.api.recoveries, hasLength(1));
  });
  testWidgets('320px 200 percent impact review remains scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = SnapshotHarness();
    addTearDown(h.dispose);
    await _pump(tester, h, SnapshotRecoveryKind.rollback, scale: 2);
    await _tap(tester, find.byKey(const Key('recovery-review')));
    await _visible(tester, find.byKey(const Key('recovery-confirmation')));
    expect(tester.takeException(), isNull);
    expect(h.api.recoveries, isEmpty);
  });
}

Future<void> _pump(
  WidgetTester tester,
  SnapshotHarness h,
  SnapshotRecoveryKind kind, {
  double scale = 1,
}) async {
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
        home: SnapshotRecoveryPage(
          session: h.session,
          kind: kind,
          snapshot: h.api.entry,
          dataset: h.api.dataset,
          selected: [h.api.entry],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _visible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 80,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _visible(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
