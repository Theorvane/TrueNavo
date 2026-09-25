import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/nfs_settings/nfs_settings_controller.dart';
import 'package:trueraid/features/nfs_settings/nfs_settings_editor.dart';
import 'package:trueraid/features/nfs_settings/nfs_settings_page.dart';
import 'package:trueraid/features/nfs_settings/nfs_settings_review.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'nfs_settings_fakes.dart';

Future<NfsHarness> pumpNfs(
  WidgetTester tester, {
  NfsFake? fake,
  bool disconnected = false,
  double width = 800,
  double scale = 1,
  double keyboard = 0,
  bool dark = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = NfsHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.load();
    } on Object {
      /* Fixed public UI. */
    }
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const NfsSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapNfs(
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

Future<void> enterNfs(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> openNfsEditor(WidgetTester t, {String change = 'threads'}) async {
  await tapNfs(t, 'nfs-edit');
  switch (change) {
    case 'threads':
      await tapNfs(t, 'nfs-automatic');
      await enterNfs(t, 'nfs-threads', '12');
    case 'protocol':
      await tapNfs(t, 'nfs-protocol-NFSV3');
    case 'binding':
      await tapNfs(t, 'nfs-bind-192.0.2.10');
    case 'mountd':
      await tapNfs(t, 'nfs-mountd-log');
    case 'statd':
      await tapNfs(t, 'nfs-statd-log');
  }
}

Future<void> openNfsReview(
  WidgetTester t, {
  String change = 'threads',
  bool settle = true,
}) async {
  await openNfsEditor(t, change: change);
  await tapNfs(t, 'nfs-editor-review', settle: settle);
}

Future<void> consentNfs(
  WidgetTester t,
  String target, {
  bool bindings = false,
}) async {
  await enterNfs(t, 'nfs-confirm-target', target);
  await tapNfs(t, 'nfs-confirm-impact');
  await tapNfs(t, 'nfs-confirm-specific');
  if (bindings) await tapNfs(t, 'nfs-confirm-bindings');
}

void background(WidgetTester t) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    t.binding.handleAppLifecycleStateChanged(state);
  }
}

void expectLocked(NfsHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(NfsHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = lock.acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'dashboard $width dark=$dark 200% configured charts, no auto writes',
        (t) async {
          final h = await pumpNfs(t, width: width, dark: dark, scale: 2);
          expect(find.byKey(const Key('nfs-enablement-ring')), findsOneWidget);
          expect(find.byKey(const Key('nfs-thread-bar')), findsOneWidget);
          expect(
            t
                .widget<FractionallySizedBox>(
                  find.byKey(const Key('nfs-thread-bar')),
                )
                .widthFactor,
            8 / 256,
          );
          await tapNfs(t, 'nfs-protected-details');
          expect(find.textContaining('Public host identity'), findsOneWidget);
          await tapNfs(t, 'nfs-scope-details');
          expect(find.textContaining('not clients'), findsOneWidget);
          expect(h.api.reads, 1);
          expect(h.api.executes, isEmpty);
          expect(t.takeException(), isNull);
        },
      );
      for (final change in [
        'threads',
        'protocol',
        'binding',
        'mountd',
        'statd',
      ]) {
        testWidgets('$change editor/review $width dark=$dark 200% keyboard', (
          t,
        ) async {
          final h = await pumpNfs(
            t,
            width: width,
            dark: dark,
            scale: 2,
            keyboard: 300,
          );
          await openNfsReview(t, change: change);
          expect(find.byType(NfsSettingsReviewDialog), findsOneWidget);
          expect(find.text('Review global NFS change'), findsOneWidget);
          await tapNfs(t, 'nfs-review-details');
          expect(find.textContaining('Synthetic supplemental'), findsOneWidget);
          expect(find.text('NFS settings review expired'), findsNothing);
          final request = h.api.reviews.single;
          await consentNfs(t, request.target, bindings: change == 'binding');
          await t.ensureVisible(find.byKey(const Key('nfs-confirm-submit')));
          await t.pumpAndSettle();
          expect(
            t
                .widget<FilledButton>(
                  find.byKey(const Key('nfs-confirm-submit')),
                )
                .onPressed,
            isNotNull,
          );
          await tapNfs(t, 'nfs-review-cancel');
          expect(h.api.executes, isEmpty);
          expect(t.takeException(), isNull);
        });
      }
    }
  }
  for (final outcome in NfsSettingsOutcome.values) {
    testWidgets('normal modal pop submits exactly once: ${outcome.name}', (
      t,
    ) async {
      final fake = NfsFake();
      fake.onExecute = (_, current) async {
        if (current()) fake.mutations++;
        return NfsSettingsResult(outcome, 'untrusted remote');
      };
      final h = await pumpNfs(t, fake: fake);
      await openNfsReview(t);
      await consentNfs(t, fake.reviews.single.target);
      await tapNfs(t, 'nfs-confirm-submit');
      expect(fake.executes, hasLength(1));
      expect(fake.mutations, 1);
      expect(fake.reads, 1);
      expect(find.textContaining('untrusted remote'), findsNothing);
      expect(find.byKey(const Key('nfs-enablement-ring')), findsNothing);
      if (outcome == NfsSettingsOutcome.unknown) {
        expectLocked(h);
      } else {
        expectUnlocked(h);
        await tapNfs(t, 'nfs-refresh-after-review');
        expect(fake.reads, 2);
      }
      expect(t.takeException(), isNull);
    });
  }
  for (final missing in ['impact', 'specific', 'bindings', 'target']) {
    testWidgets('missing $missing consent cannot submit binding change', (
      t,
    ) async {
      final h = await pumpNfs(t);
      await openNfsReview(t, change: 'binding');
      if (missing != 'target') {
        await enterNfs(t, 'nfs-confirm-target', h.api.reviews.single.target);
      }
      for (final key in ['impact', 'specific', 'bindings']) {
        if (key != missing) await tapNfs(t, 'nfs-confirm-$key');
      }
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('nfs-confirm-submit')))
            .onPressed,
        isNull,
      );
      expect(h.api.executes, isEmpty);
      await tapNfs(t, 'nfs-review-cancel');
    });
  }
  for (final phase in ['editor', 'review']) {
    for (final cause in ['background', 'session', 'inventory', 'cover']) {
      testWidgets('$phase $cause expires and clears actual text buffer', (
        t,
      ) async {
        final h = await pumpNfs(t);
        if (phase == 'editor') {
          await openNfsEditor(t);
        } else {
          await openNfsReview(t);
          await consentNfs(t, h.api.reviews.single.target);
        }
        final field = phase == 'editor' ? 'nfs-threads' : 'nfs-confirm-target';
        final buffer = t.widget<TextField>(find.byKey(Key(field))).controller!;
        expect(buffer.text, isNotEmpty);
        NavigatorState? nav;
        if (cause == 'background') background(t);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'inventory') {
          h.api.inventory = nfsInventory();
          h.container.invalidate(nfsSettingsInventoryProvider);
        }
        if (cause == 'cover') {
          nav = Navigator.of(
            t.element(
              find.byType(
                phase == 'editor'
                    ? NfsSettingsEditorDialog
                    : NfsSettingsReviewDialog,
              ),
            ),
          );
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Other route')),
              ),
            ),
          );
        }
        await t.pumpAndSettle();
        expect(buffer.text, isEmpty);
        expect(h.api.executes, isEmpty);
        if (nav != null) {
          nav.pop();
          await t.pumpAndSettle();
        }
        expect(
          find.text(
            phase == 'editor'
                ? 'NFS settings editor expired'
                : 'NFS settings review expired',
          ),
          findsOneWidget,
        );
        await tapNfs(
          t,
          phase == 'editor' ? 'nfs-editor-cancel' : 'nfs-review-cancel',
        );
        expect(t.takeException(), isNull);
      });
    }
  }
  for (final phase in ['review', 'execute']) {
    for (final cause in ['cover', 'background', 'session', 'inventory']) {
      testWidgets('held $phase $cause never dispatches late', (t) async {
        final h = await pumpNfs(t);
        final pending = Completer<void>();
        if (phase == 'review') {
          h.api.onReview = (r) async {
            await pending.future;
            return NfsSettingsReview(
              request: r,
              endpoint: r.inventory.endpoint,
              warnings: const [],
            );
          };
        }
        if (phase == 'execute') {
          h.api.onExecute = (_, current) async {
            await pending.future;
            if (current()) h.api.mutations++;
            return const NfsSettingsResult(NfsSettingsOutcome.rejected, 'late');
          };
        }
        await openNfsReview(t, settle: phase != 'review');
        if (phase == 'execute') {
          await consentNfs(t, h.api.reviews.single.target);
          await tapNfs(t, 'nfs-confirm-submit', settle: false);
        }
        NavigatorState? nav;
        if (cause == 'background') background(t);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'inventory') {
          h.api.inventory = nfsInventory();
          h.container.invalidate(nfsSettingsInventoryProvider);
        }
        if (cause == 'cover') {
          nav = Navigator.of(t.element(find.byType(NfsSettingsPage)));
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Other route')),
              ),
            ),
          );
        }
        await t.pump();
        pending.complete();
        await t.pumpAndSettle();
        expect(h.api.mutations, 0);
        expect(find.byType(NfsSettingsReviewDialog), findsNothing);
        if (phase == 'execute') expectLocked(h);
        if (nav != null) {
          nav.pop();
          await t.pumpAndSettle();
        }
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets('five-minute review expiry clears typed target', (t) async {
    final h = await pumpNfs(t);
    await openNfsReview(t);
    await consentNfs(t, h.api.reviews.single.target);
    final buffer = t
        .widget<TextField>(find.byKey(const Key('nfs-confirm-target')))
        .controller!;
    await t.pump(const Duration(minutes: 6));
    await t.pumpAndSettle();
    expect(buffer.text, isEmpty);
    expect(find.text('NFS settings review expired'), findsOneWidget);
    await tapNfs(t, 'nfs-review-cancel');
  });
  testWidgets('empty export chart has no artificial percentage', (t) async {
    final h = await pumpNfs(
      t,
      fake: NfsFake(inventory: nfsInventory(exports: [])),
    );
    expect(find.textContaining('No configured exports'), findsOneWidget);
    expect(h.api.executes, isEmpty);
  });
  for (final entry in <String, NfsSettingsInventory>{
    'running': nfsInventory(serviceState: 'RUNNING'),
    'HA': nfsInventory(ha: true),
    'directory': nfsInventory(directoryConfigured: true),
    'Kerberos': nfsInventory(kerberos: true),
    'RDMA': nfsInventory(rdma: true),
    'notREADY': nfsInventory(state: 'BOOTING'),
  }.entries) {
    testWidgets('${entry.key} shows visible blocker and readonly charts', (
      t,
    ) async {
      final h = await pumpNfs(t, fake: NfsFake(inventory: entry.value));
      expect(
        t.widget<OutlinedButton>(find.byKey(const Key('nfs-edit'))).onPressed,
        isNull,
      );
      expect(find.text(entry.value.blockedReason!), findsOneWidget);
      expect(h.api.executes, isEmpty);
    });
  }
  testWidgets('enabled exports disable protocols/bindings but allow logs', (
    t,
  ) async {
    await pumpNfs(
      t,
      fake: NfsFake(
        inventory: nfsInventory(
          exports: [
            NfsConfiguredExport(id: 1, enabled: true, security: ['SYS']),
          ],
        ),
      ),
    );
    await openNfsEditor(t, change: 'mountd');
    expect(
      t
          .widget<CheckboxListTile>(find.byKey(const Key('nfs-protocol-NFSV3')))
          .onChanged,
      isNull,
    );
    expect(
      t
          .widget<CheckboxListTile>(
            find.byKey(const Key('nfs-bind-192.0.2.10')),
          )
          .onChanged,
      isNull,
    );
    expect(
      t
          .widget<FilledButton>(find.byKey(const Key('nfs-editor-review')))
          .onPressed,
      isNotNull,
    );
    await tapNfs(t, 'nfs-editor-cancel');
  });
  testWidgets('legacy IPv6 bindings preserved on log edit', (t) async {
    final h = await pumpNfs(
      t,
      fake: NfsFake(inventory: nfsInventory(bindings: ['2001:db8::10'])),
    );
    await openNfsReview(t, change: 'mountd');
    expect(h.api.reviews.single.settings.bindAddresses, ['2001:db8::10']);
    await tapNfs(t, 'nfs-review-cancel');
  });
  testWidgets('disconnected never loads', (t) async {
    final h = await pumpNfs(t, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('NFS configuration unavailable'), findsOneWidget);
  });
  testWidgets('sanitized read error retry is explicit', (t) async {
    final fake = NfsFake()
      ..onLoad = () async => throw StateError('PRIVATE-NFS');
    final h = await pumpNfs(t, fake: fake);
    expect(find.textContaining('PRIVATE-NFS'), findsNothing);
    expect(find.byKey(const Key('nfs-retry')), findsOneWidget);
    expect(h.api.executes, isEmpty);
  });
}
