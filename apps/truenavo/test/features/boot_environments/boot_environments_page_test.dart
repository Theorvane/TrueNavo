import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/dev/boot_environments_preview.dart';
import 'package:truenavo/features/boot_environments/boot_environment_review_dialog.dart';
import 'package:truenavo/features/boot_environments/boot_environments_controller.dart';
import 'package:truenavo/features/boot_environments/boot_environments_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'boot_environments_fakes.dart';

Finder key(String value) => find.byKey(Key(value));
Finder reviewContains(String value) => find.descendant(
  of: find.byType(BootEnvironmentReviewDialog),
  matching: find.textContaining(value),
);

Future<void> reveal(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
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

Future<void> tap(WidgetTester tester, String value) async {
  await reveal(tester, key(value));
  await tester.tap(key(value));
  await tester.pumpAndSettle();
}

Future<BootHarness> pump(
  WidgetTester tester, {
  BootHarness? harness,
  double scale = 1,
  Set<String> methods = bootMethods,
  String version = '25.10.1',
  bool licensed = false,
  bool conflicting = false,
  bool connected = true,
}) async {
  final h =
      harness ??
      await BootHarness.create(
        methods: methods,
        version: version,
        licensed: licensed,
        conflicting: conflicting,
      );
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
        home: const BootEnvironmentsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> openAction(
  WidgetTester tester,
  String action, {
  String name = 'old',
}) async {
  await reveal(tester, key('boot-search'));
  await tester.enterText(key('boot-search'), name);
  await tester.pumpAndSettle();
  await tap(tester, 'boot-$action-$name');
}

Future<void> reviewAction(WidgetTester tester, String action) async {
  await openAction(tester, action);
  await tap(tester, 'boot-action-review');
}

void main() {
  testWidgets(
    'inventory shows current next-boot keep and space without mutations',
    (tester) async {
      final h = await pump(tester);
      expect(find.text('Current system'), findsOneWidget);
      expect(find.text('Next boot'), findsOneWidget);
      expect(find.text('Kept'), findsNWidgets(2));
      expect(find.text('Space used: 1.0 GiB'), findsNWidgets(4));
      expect(h.api.reads, 1);
      expect(h.api.reviews, 0);
      expect(h.transport.mutations, isEmpty);
      await reveal(tester, find.textContaining('Renaming is unavailable'));
      expect(
        find.textContaining('Bars compare reported sizes'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'relative space bars compare sizes and expose exact semantic values',
    (tester) async {
      final h = await BootHarness.create();
      h.transport.rows.first['used_bytes'] = 2147483648;
      await pump(tester, harness: h);
      final current = tester.widget<LinearProgressIndicator>(
        key('boot-space-current'),
      );
      final old = tester.widget<LinearProgressIndicator>(key('boot-space-old'));
      expect(current.value, 1);
      expect(old.value, 0.5);
      final semantics = tester.widget<Semantics>(key('boot-space-label-old'));
      expect(
        semantics.properties.label,
        'old: 1.0 GiB reported space. Bar relative to the largest reported environment.',
      );
      expect(
        find.textContaining('Bars compare reported sizes'),
        findsOneWidget,
      );
    },
  );

  testWidgets('unknown banner retains its original server after a switch', (
    tester,
  ) async {
    final h = await pump(tester);
    final review = await h.review();
    final done = Completer<BootEnvironmentResult>();
    h.api.onExecute = () => done.future;
    final operation = h.controller.execute(
      expectedSession: h.session,
      review: review,
    );
    await tester.pump();
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    done.complete(
      const BootEnvironmentResult(
        outcome: BootEnvironmentOutcome.verified,
        message: 'Late fixture completion.',
      ),
    );
    await operation;
    await tester.pumpAndSettle();
    expect(find.text('Outcome needs verification'), findsOneWidget);
    expect(find.text('Original server: $bootEndpoint'), findsOneWidget);
    expect(find.text('Target: old'), findsOneWidget);
    expect(
      tester.widget<TextButton>(key('boot-acknowledge-unknown')).onPressed,
      isNull,
    );
    expect(h.container.read(bootEnvironmentsControllerProvider).unknown, true);
  });

  testWidgets(
    'protected current kept and incompatible rows cannot be deleted',
    (tester) async {
      final h = await pump(tester);
      for (final name in ['current', 'kept', 'incompatible']) {
        expect(
          tester.widget<OutlinedButton>(key('boot-delete-$name')).onPressed,
          isNull,
        );
      }
      expect(
        tester.widget<OutlinedButton>(key('boot-delete-old')).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<OutlinedButton>(key('boot-activate-current')).onPressed,
        isNull,
      );
      expect(h.api.executions, 0);
    },
  );

  for (final scenario in ['offline', 'unsupported', 'missing-read']) {
    testWidgets('$scenario does not read inventory or expose forms', (
      tester,
    ) async {
      final h = await pump(
        tester,
        connected: scenario != 'offline',
        version: scenario == 'unsupported' ? '26.04.0' : '25.10.1',
        methods: scenario == 'missing-read'
            ? bootMethods.difference({'core.get_jobs'})
            : bootMethods,
      );
      expect(find.text('Boot environments unavailable'), findsOneWidget);
      expect(h.api.reads, 0);
      expect(key('boot-search'), findsNothing);
      expect(h.transport.mutations, isEmpty);
    });
  }

  for (final scenario in ['HA', 'conflicting update', 'read-only account']) {
    testWidgets('$scenario retains inventory and disables changes', (
      tester,
    ) async {
      final h = await pump(
        tester,
        licensed: scenario == 'HA',
        conflicting: scenario == 'conflicting update',
        methods: scenario == 'read-only account'
            ? {'boot.environment.query', 'core.get_jobs', 'failover.licensed'}
            : bootMethods,
      );
      await reveal(tester, key('boot-delete-old'));
      expect(
        tester.widget<OutlinedButton>(key('boot-delete-old')).onPressed,
        isNull,
      );
      expect(h.api.reads, 1);
      expect(h.transport.mutations, isEmpty);
    });
  }

  testWidgets('clone validation and canceled review issue no mutation', (
    tester,
  ) async {
    final h = await pump(tester);
    await openAction(tester, 'clone');
    for (final invalid in ['', 'bad name', '../unsafe', 'old']) {
      await tester.enterText(key('boot-clone-name'), invalid);
      await tap(tester, 'boot-action-review');
      expect(key('boot-action-error'), findsOneWidget);
      expect(find.byType(BootEnvironmentReviewDialog), findsNothing);
    }
    expect(h.api.reviews, 0);
    await tester.enterText(key('boot-clone-name'), 'safe-copy');
    await tap(tester, 'boot-action-review');
    expect(find.text('Exact target: safe-copy'), findsOneWidget);
    expect(h.api.reviews, 1);
    expect(h.api.executions, 0);
    await tap(tester, 'boot-review-cancel');
    expect(h.transport.mutations, isEmpty);
  });

  testWidgets('clone sends only reviewed source and exact new name', (
    tester,
  ) async {
    final h = await pump(tester);
    await openAction(tester, 'clone');
    await tester.enterText(key('boot-clone-name'), 'safe-copy');
    await tap(tester, 'boot-action-review');
    await tester.enterText(key('boot-review-confirmation'), 'safe-copy');
    await tap(tester, 'boot-review-confirm');
    expect(h.transport.mutations.single['method'], 'boot.environment.clone');
    expect(h.transport.mutations.single['params'], [
      {'id': 'old', 'target': 'safe-copy'},
    ]);
    expect(h.state.result!.outcome, BootEnvironmentOutcome.verified);
  });

  testWidgets(
    'activation requires exact name and acknowledgement and never reboots',
    (tester) async {
      final h = await pump(tester);
      await reviewAction(tester, 'activate');
      expect(reviewContains('does not reboot'), findsOneWidget);
      await tester.enterText(key('boot-review-confirmation'), 'old');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(key('boot-review-confirm')).onPressed,
        isNull,
      );
      await tap(tester, 'boot-review-acknowledge');
      for (final invalid in ['OLD', ' old', 'old ']) {
        await tester.enterText(key('boot-review-confirmation'), invalid);
        await tester.pump();
        expect(
          tester.widget<FilledButton>(key('boot-review-confirm')).onPressed,
          isNull,
        );
      }
      await tester.enterText(key('boot-review-confirmation'), 'old');
      await tap(tester, 'boot-review-confirm');
      expect(
        h.transport.mutations.single['method'],
        'boot.environment.activate',
      );
      expect(
        h.transport.rows.firstWhere((row) => row['id'] == 'old')['activated'],
        true,
      );
      expect(
        h.transport.rows.firstWhere((row) => row['id'] == 'current')['active'],
        true,
      );
      expect(
        h.transport.requests.where((r) => r['method'] == 'system.reboot'),
        isEmpty,
      );
      expect(h.state.result!.outcome, BootEnvironmentOutcome.verified);
    },
  );

  testWidgets(
    'delete names the dataset and needs separate destructive acknowledgement',
    (tester) async {
      final h = await pump(tester);
      await reviewAction(tester, 'delete');
      expect(reviewContains('boot-pool/ROOT/old'), findsOneWidget);
      expect(reviewContains('does not delete data pools'), findsOneWidget);
      await tester.enterText(key('boot-review-confirmation'), 'old');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(key('boot-review-confirm')).onPressed,
        isNull,
      );
      await tap(tester, 'boot-review-acknowledge');
      await tap(tester, 'boot-review-confirm');
      expect(
        h.transport.mutations.single['method'],
        'boot.environment.destroy',
      );
      expect(h.transport.rows.where((row) => row['id'] == 'old'), isEmpty);
      expect(h.state.result!.outcome, BootEnvironmentOutcome.verified);
    },
  );

  testWidgets(
    'keep review shows before and after and does not change activation',
    (tester) async {
      final h = await pump(tester);
      await reviewAction(tester, 'keep');
      expect(
        reviewContains('Current retention: Not kept. After change: Kept.'),
        findsOneWidget,
      );
      await tester.enterText(key('boot-review-confirmation'), 'old');
      await tap(tester, 'boot-review-confirm');
      expect(h.transport.mutations.single['params'], [
        {'id': 'old', 'value': true},
      ]);
      expect(
        h.transport.rows.firstWhere((row) => row['id'] == 'old')['activated'],
        false,
      );
    },
  );

  testWidgets(
    'connection change expires draft and hides its source and target',
    (tester) async {
      final h = await pump(tester);
      await openAction(tester, 'clone');
      await tester.enterText(key('boot-clone-name'), 'private-draft');
      h.select(null);
      await tester.pumpAndSettle();
      expect(find.text('Connection changed'), findsOneWidget);
      expect(find.textContaining('private-draft'), findsNothing);
      expect(find.text('Environment: old'), findsNothing);
      expect(key('boot-clone-name'), findsNothing);
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(key('boot-clone-name'), findsNothing);
      expect(h.api.reviews, 0);
      expect(h.api.executions, 0);
    },
  );

  testWidgets('connection change clears review confirmation permanently', (
    tester,
  ) async {
    final h = await pump(tester);
    await reviewAction(tester, 'delete');
    await tester.enterText(key('boot-review-confirmation'), 'old');
    await tap(tester, 'boot-review-acknowledge');
    h.select(null);
    await tester.pumpAndSettle();
    expect(find.text('Connection changed'), findsWidgets);
    expect(find.text('Exact target: old'), findsNothing);
    expect(key('boot-review-confirm'), findsNothing);
    h.select(h.session);
    await tester.pumpAndSettle();
    expect(key('boot-review-confirm'), findsNothing);
    await tap(tester, 'boot-review-close');
    expect(h.api.executions, 0);
  });

  testWidgets(
    'new session clears old inventory while the new read is pending',
    (tester) async {
      final h = await pump(tester);
      final pending = Completer<BootEnvironmentInventory>();
      h.api.pendingRead = pending.future;
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      await tester.pump();
      await tester.pump();
      expect(key('boot-environment-old'), findsNothing);
      expect(find.text('Dataset: boot-pool/ROOT/old'), findsNothing);
      pending.complete(
        BootEnvironmentInventory(
          environments: const [],
          failoverLicensed: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(h.api.reads, 2);
    },
  );

  testWidgets(
    'inventory errors withhold raw details and offer explicit refresh',
    (tester) async {
      final h = await BootHarness.create();
      h.api.readError = StateError('private fixture trace');
      await pump(tester, harness: h);
      expect(find.text('Could not load boot environments'), findsOneWidget);
      expect(find.textContaining('private fixture trace'), findsNothing);
      h.api.readError = null;
      await tap(tester, 'boot-retry');
      expect(key('boot-search'), findsOneWidget);
      expect(h.api.executions, 0);
    },
  );

  for (final action in ['clone', 'activate', 'delete']) {
    testWidgets('320px at 200 percent supports $action form and review', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = await pump(tester, scale: 2);
      await openAction(tester, action);
      if (action == 'clone') {
        await reveal(tester, key('boot-clone-name'));
        await tester.enterText(key('boot-clone-name'), 'safe-copy');
      }
      await tap(tester, 'boot-action-review');
      await reveal(tester, key('boot-review-confirmation'));
      expect(tester.takeException(), isNull);
      await tap(tester, 'boot-review-cancel');
      expect(h.api.executions, 0);
    });
  }

  test(
    'preview supplies synthetic inventory and rejects review issuance',
    () async {
      final preview = _Preview();
      final inventory = await preview.loadBootEnvironments();
      expect(inventory.environments.length, 3);
      expect(
        preview.bootEnvironmentsCapabilities.supports(
          BootEnvironmentAction.rename,
        ),
        false,
      );
      await expectLater(
        preview.reviewBootEnvironment(
          BootEnvironmentRequest(
            inventory: inventory,
            snapshot: inventory.environments.last,
            action: BootEnvironmentAction.delete,
          ),
        ),
        throwsStateError,
      );
      final h = await BootHarness.create();
      addTearDown(h.dispose);
      final result = await preview.executeBootEnvironment(await h.review());
      expect(result.outcome, BootEnvironmentOutcome.rejected);
      expect(h.transport.mutations, isEmpty);
    },
  );
}

class _Preview with BootEnvironmentsPreviewAdapter {}
