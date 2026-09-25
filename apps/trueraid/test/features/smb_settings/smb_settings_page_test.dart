import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/smb_settings/smb_settings_controller.dart';
import 'package:trueraid/features/smb_settings/smb_settings_page.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'smb_settings_fakes.dart';

Future<SmbHarness> pumpSmb(
  WidgetTester tester, {
  SmbFake? fake,
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
  final h = SmbHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.load();
    } on Object {
      /* Fixed safe UI. */
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
        home: const SmbSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapSmb(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
  }
  final checkbox = find.descendant(of: finder, matching: find.byType(Checkbox));
  final target = checkbox.evaluate().isNotEmpty ? checkbox : finder;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> enterSmb(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> openReview(
  WidgetTester tester, {
  bool rename = false,
  bool encryption = false,
  bool multichannel = false,
}) async {
  await tapSmb(tester, 'smb-edit');
  await enterSmb(tester, 'smb-description', 'New description');
  if (rename) await enterSmb(tester, 'smb-name', 'NEWNAS');
  if (encryption) await tapSmb(tester, 'smb-encryption-required');
  if (multichannel) await tapSmb(tester, 'smb-multichannel');
  await tapSmb(tester, 'smb-editor-next');
  expect(find.text('Review SMB change'), findsOneWidget);
}

Future<void> confirm(
  WidgetTester tester,
  SmbHarness h, {
  bool identity = false,
  bool compatibility = false,
}) async {
  await enterSmb(tester, 'smb-confirmation', h.api.reviews.last.target);
  await tapSmb(tester, 'smb-consent-impact');
  if (identity) await tapSmb(tester, 'smb-consent-identity');
  if (compatibility) await tapSmb(tester, 'smb-consent-compatibility');
  await tapSmb(tester, 'smb-submit');
}

void main() {
  for (final dark in [false, true]) {
    for (final width in [320.0, 800.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'configured ring and responsive layout $dark/$width/$scale',
          (tester) async {
            final h = await pumpSmb(
              tester,
              dark: dark,
              width: width,
              scale: scale,
            );
            await tester.scrollUntilVisible(
              find.byKey(const Key('smb-share-ring')),
              200,
              scrollable: find.byType(Scrollable).first,
            );
            expect(find.byKey(const Key('smb-share-ring')), findsOneWidget);
            expect(find.text('1 enabled\n1 disabled'), findsOneWidget);
            expect(tester.takeException(), isNull);
            expect(h.api.reads, 1);
            expect(h.api.executes, isEmpty);
          },
        );
      }
    }
  }
  for (final mode in ['description', 'rename', 'encryption', 'multichannel']) {
    testWidgets('$mode normal modal closing preserves one-shot authorization', (
      tester,
    ) async {
      final h = await pumpSmb(tester);
      await openReview(
        tester,
        rename: mode == 'rename',
        encryption: mode == 'encryption',
        multichannel: mode == 'multichannel',
      );
      expect(h.api.executes, isEmpty);
      expect(h.api.reviews, hasLength(1));
      await confirm(
        tester,
        h,
        identity: mode == 'rename',
        compatibility: mode == 'encryption' || mode == 'multichannel',
      );
      expect(h.api.mutations, 1);
      expect(h.api.executes, hasLength(1));
      expect(find.text('Configuration verified'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('small high-text editor and review with keyboard', (
    tester,
  ) async {
    final h = await pumpSmb(tester, width: 320, scale: 2, keyboard: 260);
    await openReview(
      tester,
      rename: true,
      encryption: true,
      multichannel: true,
    );
    expect(tester.takeException(), isNull);
    await confirm(tester, h, identity: true, compatibility: true);
    expect(h.api.mutations, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('all identity and compatibility consents are required', (
    tester,
  ) async {
    final h = await pumpSmb(tester);
    await openReview(tester, rename: true, encryption: true);
    await enterSmb(tester, 'smb-confirmation', h.api.reviews.last.target);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('smb-submit')))
          .onPressed,
      isNull,
    );
    await tapSmb(tester, 'smb-consent-impact');
    await tapSmb(tester, 'smb-consent-identity');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('smb-submit')))
          .onPressed,
      isNull,
    );
    await tapSmb(tester, 'smb-consent-compatibility');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('smb-submit')))
          .onPressed,
      isNotNull,
    );
    expect(h.api.executes, isEmpty);
  });
  testWidgets('invalid and unchanged fields never request review', (
    tester,
  ) async {
    final h = await pumpSmb(tester);
    await tapSmb(tester, 'smb-edit');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('smb-editor-next')))
          .onPressed,
      isNull,
    );
    await enterSmb(tester, 'smb-name', 'WORLD');
    await enterSmb(tester, 'smb-description', 'Changed');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('smb-editor-next')))
          .onPressed,
      isNull,
    );
    expect(h.api.reviews, isEmpty);
    expect(find.byType(DropdownButton<Object>), findsNothing);
  });
  for (final phase in ['editor', 'review']) {
    for (final reason in ['background', 'disconnect', 'covered']) {
      testWidgets('$phase $reason expires and clears actual buffers', (
        tester,
      ) async {
        final h = await pumpSmb(tester);
        if (phase == 'editor') {
          await tapSmb(tester, 'smb-edit');
          await enterSmb(tester, 'smb-description', 'PRIVATE_DRAFT');
        } else {
          await openReview(tester);
          await enterSmb(tester, 'smb-confirmation', h.api.reviews.last.target);
          await tapSmb(tester, 'smb-consent-impact');
        }
        final controllers = find
            .byType(TextField)
            .evaluate()
            .map((e) => (e.widget as TextField).controller)
            .whereType<TextEditingController>()
            .toList();
        if (reason == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else if (reason == 'disconnect') {
          h.select(null);
        } else {
          Navigator.of(tester.element(find.byType(Dialog))).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Covered')),
            ),
          );
        }
        await tester.pumpAndSettle();
        for (final controller in controllers) {
          expect(controller.text, isEmpty);
        }
        expect(h.api.executes, isEmpty);
        expect(tester.takeException(), isNull);
        if (reason == 'covered') {
          Navigator.of(tester.element(find.text('Covered'))).pop();
          await tester.pumpAndSettle();
        }
        expect(
          find.text(
            phase == 'editor' ? 'SMB draft expired' : 'SMB review expired',
          ),
          findsOneWidget,
        );
      });
    }
  }
  testWidgets('cancel editor clears local buffers and invokes no write', (
    tester,
  ) async {
    final h = await pumpSmb(tester);
    await tapSmb(tester, 'smb-edit');
    await enterSmb(tester, 'smb-description', 'DRAFT_TO_CLEAR');
    await tapSmb(tester, 'smb-editor-cancel');
    expect(find.text('DRAFT_TO_CLEAR'), findsNothing);
    expect(h.api.reviews, isEmpty);
    expect(h.api.executes, isEmpty);
  });
  testWidgets('cancel review does not execute', (tester) async {
    final h = await pumpSmb(tester);
    await openReview(tester);
    await tapSmb(tester, 'smb-review-cancel');
    expect(h.api.executes, isEmpty);
  });
  testWidgets('empty configuration has readable zero counts', (tester) async {
    final h = await pumpSmb(
      tester,
      fake: SmbFake(inventory: smbInventory(shares: const [])),
    );
    await tapSmb(tester, 'smb-reload');
    expect(h.api.executes, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text(
        'No configured SMB shares. This does not establish runtime access or service status.',
      ),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text(
        'No configured SMB shares. This does not establish runtime access or service status.',
      ),
      findsOneWidget,
    );
  });
  for (final mode in ['directory', 'security', 'auxiliary']) {
    testWidgets('$mode protected profile remains read-only', (tester) async {
      final h = await pumpSmb(
        tester,
        fake: SmbFake(
          inventory: smbInventory(
            directory: mode == 'directory',
            security: mode == 'security',
            aux: mode == 'auxiliary',
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('smb-edit')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('smb-edit')))
            .onPressed,
        isNull,
      );
      expect(h.api.reviews, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('read error does not expose remote details or retry', (
    tester,
  ) async {
    final fake = SmbFake()
      ..onLoad = () => Future.error(StateError('PRIVATE_REMOTE'));
    final h = await pumpSmb(tester, fake: fake);
    expect(find.text('SMB settings unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE_REMOTE'), findsNothing);
    expect(h.api.reads, 1);
    expect(h.api.executes, isEmpty);
  });
  testWidgets('disconnected page is readable without load', (tester) async {
    final h = await pumpSmb(tester, disconnected: true);
    expect(find.text('Global SMB settings'), findsOneWidget);
    expect(h.api.reads, 0);
    expect(h.api.executes, isEmpty);
  });
  testWidgets('unknown result holds cross-route lock and no auto read', (
    tester,
  ) async {
    final h = await pumpSmb(tester);
    h.api.onExecute = (_, _) async =>
        const SmbSettingsResult(SmbSettingsOutcome.unknown, 'PRIVATE_REMOTE');
    await openReview(tester);
    await confirm(tester, h);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    expect(h.api.reads, 1);
    expect(find.textContaining('PRIVATE_REMOTE'), findsNothing);
    expect(find.byKey(const Key('smb-edit')), findsNothing);
    expect(h.api.executes, hasLength(1));
  });
  testWidgets('background during held dispatch remains unknown', (
    tester,
  ) async {
    final h = await pumpSmb(tester);
    final held = Completer<SmbSettingsResult>();
    h.api.onExecute = (_, _) => held.future;
    await openReview(tester);
    await confirm(tester, h);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    held.complete(
      const SmbSettingsResult(SmbSettingsOutcome.completed, 'Late'),
    );
    await tester.pumpAndSettle();
    expect(
      h.container.read(smbSettingsControllerProvider).status,
      SmbSettingsStatus.unknown,
    );
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
}
