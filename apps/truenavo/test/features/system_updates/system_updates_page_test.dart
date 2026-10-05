import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/dev/system_updates_preview.dart';
import 'package:truenavo/features/system_updates/system_update_review.dart';
import 'package:truenavo/features/system_updates/system_updates_controller.dart';
import 'package:truenavo/features/system_updates/system_updates_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'system_updates_fakes.dart';

class _Preview with SystemUpdatesPreviewAdapter {
  const _Preview();
}

Future<UpdatesHarness> pumpUpdates(
  WidgetTester tester, {
  UpdatesFake? fake,
  double width = 800,
  double scale = 1,
  bool light = false,
  bool disconnected = false,
  bool awaitInventory = true,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = UpdatesHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) h.select(null);
  if (awaitInventory && !disconnected) {
    await h.container.read(systemUpdatesInventoryProvider.future);
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
        home: const SystemUpdatesPage(),
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

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapUpdate(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> confirmUpdate(WidgetTester tester, String target) async {
  final input = find.byKey(const Key('updates-confirm-target'));
  await reveal(tester, input);
  await tester.enterText(input, target);
  await tester.pumpAndSettle();
  await tapUpdate(tester, 'updates-confirm-impact');
  await tapUpdate(tester, 'updates-confirm-submit');
}

void main() {
  testWidgets('opening and local refresh never check source, submit or poll', (
    tester,
  ) async {
    final h = await pumpUpdates(
      tester,
      fake: UpdatesFake(inventory: updatesInventory(checked: false)),
    );
    expect(find.text('Not checked this session'), findsOneWidget);
    expect(find.byKey(const Key('updates-download-0')), findsNothing);
    await tapUpdate(tester, 'updates-refresh');
    expect(h.api.reads, 2);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
    expect(h.api.polls, isEmpty);
  });
  testWidgets(
    'source check requires exact typed target and separate impact consent',
    (tester) async {
      final h = await pumpUpdates(
        tester,
        fake: UpdatesFake(inventory: updatesInventory(checked: false)),
      );
      h.api.onExecute = () async => SystemUpdateResult(
        SystemUpdateOutcome.checked,
        'Checked',
        inventory: updatesInventory(),
      );
      await tapUpdate(tester, 'updates-check');
      expect(h.api.reviews.single.action, SystemUpdateAction.check);
      expect(h.api.writes, isEmpty);
      expect(find.text('CHECK 25.10.1'), findsOneWidget);
      expect(find.textContaining('may initialize'), findsWidgets);
      await reveal(tester, find.byKey(const Key('updates-confirm-target')));
      await tester.enterText(
        find.byKey(const Key('updates-confirm-target')),
        'CHECK 25.10.1 ',
      );
      await tester.pumpAndSettle();
      await tapUpdate(tester, 'updates-confirm-impact');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('updates-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('updates-confirm-target')),
        'CHECK 25.10.1',
      );
      await tester.pumpAndSettle();
      await tapUpdate(tester, 'updates-confirm-submit');
      expect(h.api.writes.single.action, SystemUpdateAction.check);
      expect(
        find.text('Checked catalog · 1 releases · 1 trains'),
        findsOneWidget,
      );
      expect(h.api.polls, isEmpty);
    },
  );
  testWidgets('canceling check, download and install sends nothing', (
    tester,
  ) async {
    final h = await pumpUpdates(tester);
    for (final key in [
      'updates-check',
      'updates-download-0',
      'updates-install-0',
    ]) {
      await tapUpdate(tester, key);
      await tapUpdate(tester, 'updates-confirm-cancel');
    }
    expect(h.api.reviews.length, 3);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'download review shows immutable exact endpoint and source fields',
    (tester) async {
      final h = await pumpUpdates(tester);
      await tapUpdate(tester, 'updates-download-0');
      expect(
        find.widgetWithText(SelectableText, updatesEndpoint),
        findsOneWidget,
      );
      expect(find.text('DOWNLOAD 25.10.2'), findsOneWidget);
      expect(find.text('Image: TrueNAS-SCALE-25.10.2.update'), findsOneWidget);
      expect(
        find.textContaining('checksum (not independently verified)'),
        findsOneWidget,
      );
      expect(find.textContaining('retry internally'), findsOneWidget);
      await confirmUpdate(tester, 'DOWNLOAD 25.10.2');
      expect(h.api.writes.single.request.version, same(updatesVersion));
      expect(h.api.polls, isEmpty);
    },
  );
  testWidgets(
    'install review explains Keep, raw capacity, no upload/resume/reboot',
    (tester) async {
      final h = await pumpUpdates(tester);
      await tapUpdate(tester, 'updates-install-0');
      expect(
        find.textContaining('Every inactive boot environment'),
        findsOneWidget,
      );
      expect(
        find.textContaining('not proof of sufficient installation capacity'),
        findsWidgets,
      );
      expect(
        find.textContaining('never uploads an image, resumes'),
        findsOneWidget,
      );
      await confirmUpdate(tester, 'INSTALL 25.10.2');
      expect(h.api.writes.single.action, SystemUpdateAction.install);
    },
  );
  testWidgets('unknown and zero capacity stay honest and block installation', (
    tester,
  ) async {
    await pumpUpdates(
      tester,
      fake: UpdatesFake(
        inventory: updatesInventory(size: null, allocated: null, free: 0),
      ),
    );
    expect(find.text('Size: Unknown'), findsOneWidget);
    expect(find.text('Allocated: Unknown'), findsOneWidget);
    expect(find.text('Free: 0 B'), findsOneWidget);
    expect(find.byKey(const Key('updates-boot-capacity')), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('updates-install-0')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('updates-download-0')))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('zero allocated capacity is zero not progress or unavailable', (
    tester,
  ) async {
    await pumpUpdates(
      tester,
      fake: UpdatesFake(inventory: updatesInventory(allocated: 0)),
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('updates-boot-capacity')),
          )
          .value,
      0,
    );
    expect(find.text('Allocated: 0 B'), findsOneWidget);
  });
  testWidgets('wide summary panels have equal height', (tester) async {
    await pumpUpdates(tester);
    expect(
      tester.getSize(find.byKey(const Key('updates-summary-version'))).height,
      tester.getSize(find.byKey(const Key('updates-summary-capacity'))).height,
    );
  });
  for (final light in [false, true]) {
    testWidgets(
      '320px 200% ${light ? 'light' : 'dark'} page and whole review remain usable with keyboard',
      (tester) async {
        final h = await pumpUpdates(tester, width: 320, scale: 2, light: light);
        await tapUpdate(tester, 'updates-install-0');
        tester.view.viewInsets = const FakeViewPadding(bottom: 350);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await reveal(tester, find.byKey(const Key('updates-confirm-target')));
        await tester.enterText(
          find.byKey(const Key('updates-confirm-target')),
          'INSTALL 25.10.2',
        );
        await tester.pumpAndSettle();
        await tapUpdate(tester, 'updates-confirm-impact');
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const Key('updates-confirm-impact')),
              )
              .value,
          isTrue,
        );
        await tapUpdate(tester, 'updates-confirm-submit');
        expect(h.api.writes.length, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('missing methods disable individual actions with a reason', (
    tester,
  ) async {
    await pumpUpdates(
      tester,
      fake: UpdatesFake(
        caps: const SystemUpdatesCapabilities(
          connected: true,
          versionSupported: true,
          available: true,
          canCheck: false,
          canDownload: false,
          canInstall: false,
        ),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('updates-check')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('updates-download-0')))
          .onPressed,
      isNull,
    );
    expect(
      find.textContaining('required public methods or permissions are missing'),
      findsWidgets,
    );
  });
  testWidgets('disconnected screen never loads local or upstream information', (
    tester,
  ) async {
    final h = await pumpUpdates(tester, disconnected: true);
    expect(find.text('System updates unavailable'), findsOneWidget);
    expect(h.api.reads, 0);
    expect(h.api.writes, isEmpty);
  });
  for (final caps in [
    const SystemUpdatesCapabilities(
      connected: true,
      versionSupported: false,
      available: true,
      canCheck: true,
      canDownload: true,
      canInstall: true,
    ),
    const SystemUpdatesCapabilities(
      connected: true,
      versionSupported: true,
      available: false,
      canCheck: false,
      canDownload: false,
      canInstall: false,
    ),
  ]) {
    testWidgets(
      'unsupported or unavailable contract is read-free: ${caps.versionSupported}',
      (tester) async {
        final h = await pumpUpdates(
          tester,
          fake: UpdatesFake(caps: caps),
          awaitInventory: false,
        );
        expect(find.text('System updates unavailable'), findsOneWidget);
        expect(h.api.reads, 0);
      },
    );
  }
  testWidgets(
    'local read failures are redacted and retry only after a button',
    (tester) async {
      final fake = UpdatesFake()
        ..onLoad = () => Future.error(StateError('private traceback'));
      final h = await pumpUpdates(tester, fake: fake, awaitInventory: false);
      expect(find.text('Local update information unavailable'), findsOneWidget);
      expect(find.textContaining('private traceback'), findsNothing);
      await tester.pump(const Duration(seconds: 20));
      expect(h.api.reads, 1);
      fake.onLoad = null;
      await tapUpdate(tester, 'updates-retry');
      expect(h.api.reads, 2);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('loading local safety state cannot trigger a source check', (
    tester,
  ) async {
    final completer = Completer<SystemUpdateInventory>();
    final h = await pumpUpdates(
      tester,
      fake: UpdatesFake()..onLoad = () => completer.future,
      awaitInventory: false,
      settle: false,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('updates-check')), findsNothing);
    completer.complete(h.api.inventory);
    await tester.pumpAndSettle();
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'source errors and profile mismatch block target actions without leaking errors',
    (tester) async {
      await pumpUpdates(
        tester,
        fake: UpdatesFake(
          inventory: updatesInventory(
            checkError: 'private upstream error',
            matchesProfile: false,
          ),
        ),
      );
      expect(find.text('Source check did not complete'), findsOneWidget);
      expect(find.textContaining('private upstream error'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('updates-download-0')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('updates-install-0')))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('empty checked catalog is not represented as up-to-date', (
    tester,
  ) async {
    await pumpUpdates(
      tester,
      fake: UpdatesFake(inventory: updatesInventory(versions: const [])),
    );
    expect(
      find.text('Checked catalog · 0 releases · 0 trains'),
      findsOneWidget,
    );
    expect(
      find.text(
        'No releases were returned. This does not prove the server is up to date.',
      ),
      findsOneWidget,
    );
  });
  testWidgets(
    'unprotected inactive boot environment blocks only installation',
    (tester) async {
      await pumpUpdates(
        tester,
        fake: UpdatesFake(inventory: updatesInventory(keep: false)),
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('updates-install-0')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('updates-download-0')))
            .onPressed,
        isNotNull,
      );
      expect(
        find.textContaining('Protect every inactive boot environment'),
        findsOneWidget,
      );
    },
  );
  for (final inventory in [
    updatesInventory(ha: true),
    updatesInventory(healthy: false),
    updatesInventory(conflictingJob: true),
  ]) {
    testWidgets(
      'unsafe local state blocks all update actions: ${inventory.blockedReason}',
      (tester) async {
        await pumpUpdates(tester, fake: UpdatesFake(inventory: inventory));
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('updates-check')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('updates-download-0')),
              )
              .onPressed,
          isNull,
        );
      },
    );
  }
  testWidgets(
    'review expiration is permanent across transient disconnect and restoration',
    (tester) async {
      final h = await pumpUpdates(tester);
      await tapUpdate(tester, 'updates-download-0');
      h.select(null);
      await tester.pump();
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(find.text('Review is no longer current'), findsOneWidget);
      expect(find.byKey(const Key('updates-confirm-target')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('updates-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'refresh to the same inventory object permanently expires the review',
    (tester) async {
      final h = await pumpUpdates(tester);
      await tapUpdate(tester, 'updates-download-0');
      h.container.invalidate(systemUpdatesInventoryProvider);
      await tester.pumpAndSettle();
      expect(find.text('Review is no longer current'), findsOneWidget);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'async review never appears after transient connection replacement',
    (tester) async {
      final completer = Completer<SystemUpdateReview>();
      final h = await pumpUpdates(
        tester,
        fake: UpdatesFake()..onReview = (_) => completer.future,
      );
      await tapUpdate(tester, 'updates-download-0');
      final request = h.api.reviews.single;
      h.select(null);
      await tester.pump();
      h.select(h.session);
      await tester.pumpAndSettle();
      completer.complete(
        SystemUpdateReview(
          request: request,
          endpoint: updatesEndpoint,
          warnings: const [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SystemUpdateReviewDialog), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'foreign endpoint review is rejected with redacted safe feedback',
    (tester) async {
      final fake = UpdatesFake()
        ..onReview = (request) async => SystemUpdateReview(
          request: request,
          endpoint: 'wss://foreign.example/api/current',
          warnings: const [],
        );
      final h = await pumpUpdates(tester, fake: fake);
      await tapUpdate(tester, 'updates-download-0');
      expect(find.byType(SystemUpdateReviewDialog), findsNothing);
      expect(
        find.textContaining('could not be reviewed safely'),
        findsOneWidget,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'pending job has manual polling only and unknown read remains recoverable',
    (tester) async {
      final fake = UpdatesFake()
        ..onExecute = () async => SystemUpdateResult(
          SystemUpdateOutcome.pending,
          'Queued',
          job: updatesJob(),
          percent: 0,
        );
      final h = await pumpUpdates(tester, fake: fake);
      await tapUpdate(tester, 'updates-download-0');
      await confirmUpdate(tester, 'DOWNLOAD 25.10.2');
      expect(find.text('Update job pending'), findsOneWidget);
      expect(find.text('Server-reported job progress: 0.0%'), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.polls, isEmpty);
      h.api.onPoll = () => Future.error(StateError('private poll'));
      await tapUpdate(tester, 'updates-poll');
      expect(h.api.polls.length, 1);
      expect(find.byKey(const Key('updates-poll')), findsOneWidget);
      expect(find.text('Update outcome needs verification'), findsOneWidget);
      expect(find.textContaining('private poll'), findsNothing);
      h.api.onPoll = () async => const SystemUpdateResult(
        SystemUpdateOutcome.failed,
        'Terminal failure',
      );
      await tapUpdate(tester, 'updates-poll');
      expect(find.byKey(const Key('updates-poll')), findsNothing);
      expect(find.textContaining('partial update effects'), findsOneWidget);
      expect(h.api.writes.length, 1);
    },
  );
  testWidgets(
    'install success requiring reboot stays fenced with no reboot button',
    (tester) async {
      final h = await pumpUpdates(
        tester,
        fake: UpdatesFake()
          ..onExecute = () async => const SystemUpdateResult(
            SystemUpdateOutcome.succeeded,
            'Installed',
            rebootRequired: true,
          ),
      );
      await tapUpdate(tester, 'updates-install-0');
      await confirmUpdate(tester, 'INSTALL 25.10.2');
      expect(
        find.text('Server requires reboot — verify in TrueNAS'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Reboot'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Reboot'), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('updates-refresh')))
            .onPressed,
        isNull,
      );
      expect(h.container.read(systemUpdatesControllerProvider).locked, isTrue);
    },
  );
  testWidgets(
    'unknown retains original origin across reconnect and never replays',
    (tester) async {
      final h = await pumpUpdates(
        tester,
        fake: UpdatesFake()
          ..onExecute = () async =>
              const SystemUpdateResult(SystemUpdateOutcome.unknown, 'Unknown'),
      );
      await tapUpdate(tester, 'updates-download-0');
      await confirmUpdate(tester, 'DOWNLOAD 25.10.2');
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      await tester.pumpAndSettle();
      expect(find.text('Original server: $updatesEndpoint'), findsOneWidget);
      expect(find.byKey(const Key('updates-acknowledge')), findsNothing);
      expect(find.byKey(const Key('updates-download-0')), findsNothing);
      h.select(h.newSession());
      await tester.pumpAndSettle();
      await tapUpdate(tester, 'updates-acknowledge');
      expect(h.api.writes.length, 1);
      expect(h.api.polls, isEmpty);
      expect(
        find.textContaining(
          'no check, download, installation or reboot was replayed',
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'invalid server download percentage is not rendered as progress',
    (tester) async {
      await pumpUpdates(
        tester,
        fake: UpdatesFake(
          inventory: updatesInventory(downloadPercent: double.nan),
        ),
      );
      expect(find.text('Reported download: Unknown'), findsOneWidget);
      expect(find.textContaining('NaN'), findsNothing);
    },
  );
  test(
    'const preview fixture is immutable and every execution and poll rejects',
    () async {
      const preview = _Preview();
      final inventory = await preview.loadSystemUpdates();
      expect(inventory.endpoint, 'wss://nas-demo.example/api/current');
      expect(inventory.currentVersion, '25.10.1');
      expect(inventory.versions.single.version, '25.10.2');
      expect(inventory.checked, isTrue);
      expect(inventory.bootSizeBytes, 68719476736);
      expect(inventory.environments.every((e) => e.keep), isTrue);
      expect(() => inventory.versions.clear(), throwsUnsupportedError);
      expect(() => inventory.environments.clear(), throwsUnsupportedError);
      for (final action in SystemUpdateAction.values) {
        final request = SystemUpdateRequest(
          inventory: inventory,
          action: action,
          version: action == SystemUpdateAction.check
              ? null
              : inventory.versions.single,
        );
        final review = await preview.reviewSystemUpdate(request);
        expect(
          (await preview.executeSystemUpdate(review, review.target)).outcome,
          SystemUpdateOutcome.rejected,
        );
      }
      expect(
        (await preview.pollSystemUpdate(updatesJob())).outcome,
        SystemUpdateOutcome.rejected,
      );
      await expectLater(
        preview.reviewSystemUpdate(
          SystemUpdateRequest(
            inventory: updatesInventory(),
            action: SystemUpdateAction.check,
          ),
        ),
        throwsA(isA<SystemUpdatesException>()),
      );
    },
  );
}
