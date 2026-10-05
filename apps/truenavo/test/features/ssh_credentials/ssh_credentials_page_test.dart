import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/ssh_credentials/ssh_credentials_controller.dart';
import 'package:truenavo/features/ssh_credentials/ssh_credentials_editor.dart';
import 'package:truenavo/features/ssh_credentials/ssh_credentials_page.dart';
import 'package:truenavo/features/ssh_credentials/ssh_credentials_review.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'ssh_credentials_fakes.dart';

Future<SshHarness> pumpSsh(
  WidgetTester tester, {
  SshFake? fake,
  bool disconnected = false,
  double width = 800,
  double scale = 1,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = SshHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.container.read(sshCredentialsInventoryProvider.future);
    } on Object {
      /* Safe error UI. */
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
        home: const SshCredentialsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapSsh(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enterSsh(WidgetTester tester, String key, String value) async {
  if (key == 'ssh-credential-private-key') {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call.method);
        return call.method == 'Clipboard.getData' ? {'text': value} : null;
      },
    );
    await tapSsh(tester, 'ssh-credential-paste-private');
    expect(calls.where((call) => call == 'Clipboard.getData'), hasLength(1));
    expect(calls, isNot(contains('Clipboard.setData')));
    expect(
      tester.widget<TextField>(find.byKey(Key(key))).controller!.text,
      value,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    return;
  }
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> startSshReview(
  WidgetTester tester, {
  bool importing = false,
}) async {
  await tapSsh(
    tester,
    'ssh-credentials-${importing ? 'importKeyPair' : 'generateKeyPair'}',
  );
  await enterSsh(tester, 'ssh-credential-name', 'New identity');
  if (importing) {
    await enterSsh(tester, 'ssh-credential-private-key', sshSyntheticPrivate);
  }
  await tapSsh(tester, 'ssh-credential-editor-review');
}

Future<void> confirmSsh(WidgetTester tester, String target) async {
  await enterSsh(tester, 'ssh-credential-confirm-target', target);
  await tapSsh(tester, 'ssh-credential-confirm-impact');
  await tapSsh(tester, 'ssh-credential-confirm-submit');
}

Future<void> fillConnection(WidgetTester tester) async {
  await tapSsh(tester, 'ssh-credentials-createConnection');
  await enterSsh(tester, 'ssh-credential-name', 'New destination');
  await enterSsh(tester, 'ssh-credential-host', 'backup.example');
  await enterSsh(tester, 'ssh-credential-username', 'backup');
  await tapSsh(tester, 'ssh-credential-keypair');
  await tester.tap(find.text('Unused identity · ID 2').last);
  await tester.pumpAndSettle();
  await enterSsh(tester, 'ssh-credential-host-keys', sshPublic);
}

void main() {
  testWidgets(
    'SSH type legend colors and counts match the painted donut segments',
    (tester) async {
      await pumpSsh(tester);
      final keyColor = tester
          .widget<Icon>(find.byKey(const Key('ssh-credentials-keypair-color')))
          .color!;
      final connectionColor = tester
          .widget<Icon>(
            find.byKey(const Key('ssh-credentials-connection-color')),
          )
          .color!;
      expect(keyColor, isNot(connectionColor));
      final ring = tester.widget<CustomPaint>(
        find.byKey(const Key('ssh-credentials-inventory-donut')),
      );
      final canvas = _SshRingCanvas();
      ring.painter!.paint(canvas, const Size(124, 124));
      // Paint stores color channels at different floating-point precision.
      expect(canvas.colors.map((color) => color.toARGB32()), [
        keyColor.toARGB32(),
        connectionColor.toARGB32(),
      ]);
      expect(
        canvas.sweeps.first / canvas.sweeps.reduce((a, b) => a + b),
        closeTo(2 / 3, .00001),
      );
      expect(find.text('2 Keypair records'), findsOneWidget);
      expect(find.text('1 Connection configurations'), findsOneWidget);
      expect(find.text('Dependency status'), findsOneWidget);
      expect(find.text('1 Referenced credentials'), findsOneWidget);
      expect(find.text('2 Unused credentials'), findsOneWidget);
    },
  );
  testWidgets(
    'open and refresh only read public inventory and render metadata chart',
    (tester) async {
      final h = await pumpSsh(tester);
      expect(
        find.byKey(const Key('ssh-credentials-inventory-donut')),
        findsOneWidget,
      );
      expect(find.text('2 Keypair records'), findsOneWidget);
      expect(find.text('1 Connection configurations'), findsOneWidget);
      expect(find.textContaining('not working authentication'), findsOneWidget);
      await tapSsh(tester, 'ssh-credentials-refresh');
      expect(h.api.reads, 2);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'disconnected page never asks for credentials or contacts server',
    (tester) async {
      final h = await pumpSsh(tester, disconnected: true);
      expect(
        find.text('SSH credential management unavailable'),
        findsOneWidget,
      );
      expect(h.api.reads, 0);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'empty inventory disables destination creation and shows explanation',
    (tester) async {
      await pumpSsh(
        tester,
        fake: SshFake(inventory: sshInventory(empty: true)),
      );
      expect(find.text('No SSH credentials'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('ssh-credentials-createConnection')),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('referenced credential cannot rename or delete without cascade', (
    tester,
  ) async {
    final h = await pumpSsh(tester);
    for (final action in ['rename', 'delete']) {
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(Key('ssh-credential-$action-1')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(Key('ssh-credential-$action-2')))
            .onPressed,
        isNotNull,
      );
    }
    expect(h.api.writes, isEmpty);
  });
  testWidgets('conflicting job disables all changes while showing inventory', (
    tester,
  ) async {
    await pumpSsh(
      tester,
      fake: SshFake(inventory: sshInventory(conflict: true)),
    );
    expect(find.textContaining('active server job'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('ssh-credentials-generateKeyPair')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('ssh-credential-delete-2')),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets('missing action capabilities disable their controls', (
    tester,
  ) async {
    await pumpSsh(
      tester,
      fake: SshFake(
        caps: const SshCredentialsCapabilities(
          connected: true,
          versionSupported: true,
          available: true,
          canImport: false,
          canGenerate: false,
          canCreateConnection: false,
          canRename: false,
          canDelete: false,
        ),
      ),
    );
    for (final action in [
      'importKeyPair',
      'generateKeyPair',
      'createConnection',
    ]) {
      expect(
        tester
            .widget<FilledButton>(find.byKey(Key('ssh-credentials-$action')))
            .onPressed,
        isNull,
      );
    }
  });
  testWidgets('read errors are withheld and only manually retried', (
    tester,
  ) async {
    final api = SshFake()
      ..onLoad = () => Future.error(StateError(sshSyntheticPrivate));
    final h = await pumpSsh(tester, fake: api);
    expect(find.text('SSH credential inventory unavailable'), findsOneWidget);
    expect(find.textContaining(sshSyntheticPrivate), findsNothing);
    expect(h.api.reads, 1);
    await tapSsh(tester, 'ssh-credentials-retry');
    expect(h.api.reads, 2);
  });
  testWidgets(
    'generation is a separate reviewed operation with no private input',
    (tester) async {
      final h = await pumpSsh(tester);
      await startSshReview(tester);
      expect(h.api.reviews.single.action, SshCredentialAction.generateKeyPair);
      expect(find.byKey(const Key('ssh-credential-private-key')), findsNothing);
      expect(h.api.writes, isEmpty);
      await enterSsh(
        tester,
        'ssh-credential-confirm-target',
        'GENERATE New identity ',
      );
      await tapSsh(tester, 'ssh-credential-confirm-impact');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('ssh-credential-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await enterSsh(
        tester,
        'ssh-credential-confirm-target',
        'GENERATE New identity',
      );
      await tapSsh(tester, 'ssh-credential-confirm-submit');
      expect(h.api.writes.length, 1);
      expect(h.api.inputs.single, isNull);
      expect(
        find.byKey(const Key('ssh-credentials-result-public-key')),
        findsOneWidget,
      );
      expect(find.textContaining('BEGIN OPENSSH PRIVATE KEY'), findsNothing);
    },
  );
  testWidgets(
    'import field is concealed and review contains no private material',
    (tester) async {
      final h = await pumpSsh(tester);
      await tapSsh(tester, 'ssh-credentials-importKeyPair');
      final field = tester.widget<TextField>(
        find.byKey(const Key('ssh-credential-private-key')),
      );
      expect(field.obscureText, isTrue);
      expect(field.readOnly, isTrue);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      await enterSsh(tester, 'ssh-credential-name', 'New identity');
      await enterSsh(tester, 'ssh-credential-private-key', sshSyntheticPrivate);
      await tapSsh(tester, 'ssh-credential-editor-review');
      expect(field.controller!.text, isEmpty);
      expect(
        h.api.reviews.single.toString(),
        isNot(contains(sshSyntheticPrivate)),
      );
      expect(find.textContaining(sshSyntheticPrivate), findsNothing);
      await confirmSsh(tester, 'IMPORT New identity');
      expect(h.api.inputs.single!.disposed, isTrue);
      expect(
        h.container.read(sshCredentialsControllerProvider).result!.publicKey,
        sshPublic,
      );
    },
  );
  testWidgets('invalid private input never reaches review', (tester) async {
    final h = await pumpSsh(tester);
    await tapSsh(tester, 'ssh-credentials-importKeyPair');
    await enterSsh(tester, 'ssh-credential-name', 'New identity');
    await enterSsh(tester, 'ssh-credential-private-key', 'not an OpenSSH key');
    await tapSsh(tester, 'ssh-credential-editor-review');
    expect(h.api.reviews, isEmpty);
    expect(find.textContaining('unencrypted'), findsWidgets);
  });
  testWidgets(
    'clipboard is read only by explicit paste; clear never writes it',
    (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return call.method == 'Clipboard.getData'
              ? {'text': sshSyntheticPrivate}
              : null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final h = await pumpSsh(tester);
      await tapSsh(tester, 'ssh-credentials-importKeyPair');
      // hasStrings only checks availability for Flutter's edit toolbar.
      expect(calls.where((call) => call == 'Clipboard.getData'), isEmpty);
      await tapSsh(tester, 'ssh-credential-paste-private');
      final controller = tester
          .widget<TextField>(
            find.byKey(const Key('ssh-credential-private-key')),
          )
          .controller!;
      expect(controller.text, sshSyntheticPrivate);
      await tapSsh(tester, 'ssh-credential-clear-private');
      expect(controller.text, isEmpty);
      expect(
        calls.where(
          (call) => call == 'Clipboard.getData' || call == 'Clipboard.setData',
        ),
        ['Clipboard.getData'],
      );
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );
  for (final transition in ['background', 'connection', 'close']) {
    testWidgets('pending clipboard result is discarded on $transition', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final pending = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? pending.future : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final h = await pumpSsh(tester);
      await tapSsh(tester, 'ssh-credentials-importKeyPair');
      final controller = tester
          .widget<TextField>(
            find.byKey(const Key('ssh-credential-private-key')),
          )
          .controller!;
      await tapSsh(tester, 'ssh-credential-paste-private');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('ssh-credential-editor-review')),
            )
            .onPressed,
        isNull,
      );
      if (transition == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      } else if (transition == 'connection') {
        h.select(h.newSession());
      } else {
        await tapSsh(tester, 'ssh-credential-editor-cancel');
      }
      pending.complete({'text': sshSyntheticPrivate});
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(find.textContaining(sshSyntheticPrivate), findsNothing);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    });
  }
  for (final invalid in ['oversized', 'empty', 'error']) {
    testWidgets('$invalid clipboard content is not retained or imported', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method != 'Clipboard.getData') return null;
          if (invalid == 'error') {
            throw PlatformException(code: 'SENSITIVE_CLIPBOARD_FAILURE');
          }
          return {'text': invalid == 'empty' ? '' : 'x' * 65537};
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final h = await pumpSsh(tester);
      await tapSsh(tester, 'ssh-credentials-importKeyPair');
      await tapSsh(tester, 'ssh-credential-paste-private');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('ssh-credential-private-key')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(find.textContaining('SENSITIVE_CLIPBOARD_FAILURE'), findsNothing);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets(
    'manual destination needs an explicit independent fingerprint acknowledgement',
    (tester) async {
      final h = await pumpSsh(tester);
      await fillConnection(tester);
      expect(find.text(sshPublicKeyFingerprint(sshPublic)!), findsWidgets);
      await tapSsh(tester, 'ssh-credential-editor-review');
      expect(h.api.reviews, isEmpty);
      await tapSsh(tester, 'ssh-credential-host-verified');
      await tapSsh(tester, 'ssh-credential-editor-review');
      final request = h.api.reviews.single;
      expect(request.action, SshCredentialAction.createConnection);
      expect(request.hostKeyVerified, isTrue);
      expect(request.connection!.keyPairId, 2);
      expect(find.text('New name: New destination'), findsOneWidget);
      expect(find.text('Keypair ID: 2'), findsOneWidget);
      expect(find.text('Connection timeout: 10 seconds'), findsOneWidget);
      expect(h.api.writes, isEmpty);
      await confirmSsh(tester, request.target);
      expect(h.api.writes.length, 1);
      expect(h.api.inputs.single, isNull);
    },
  );
  testWidgets(
    'editing the destination invalidates its prior host trust acknowledgement',
    (tester) async {
      final h = await pumpSsh(tester);
      await fillConnection(tester);
      await tapSsh(tester, 'ssh-credential-host-verified');
      await enterSsh(tester, 'ssh-credential-host', 'changed.example');
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('ssh-credential-host-verified')),
            )
            .value,
        isFalse,
      );
      await tapSsh(tester, 'ssh-credential-editor-review');
      expect(h.api.reviews, isEmpty);
    },
  );
  testWidgets('name-only rename does not offer attribute replacement', (
    tester,
  ) async {
    final h = await pumpSsh(tester);
    await tapSsh(tester, 'ssh-credential-rename-2');
    expect(find.byKey(const Key('ssh-credential-private-key')), findsNothing);
    expect(find.byKey(const Key('ssh-credential-host')), findsNothing);
    await enterSsh(tester, 'ssh-credential-name', 'Renamed identity');
    await tapSsh(tester, 'ssh-credential-editor-review');
    final request = h.api.reviews.single;
    expect(request.connection, isNull);
    expect(request.credential!.id, 2);
    expect(find.text('New name: Renamed identity'), findsOneWidget);
    await confirmSsh(tester, request.target);
    expect(h.api.inputs.single, isNull);
  });
  testWidgets('delete goes to exact-target review with no credential editor', (
    tester,
  ) async {
    final h = await pumpSsh(tester);
    await tapSsh(tester, 'ssh-credential-delete-2');
    expect(find.byType(SshCredentialsEditor), findsNothing);
    expect(h.api.writes, isEmpty);
    expect(h.api.reviews.single.action, SshCredentialAction.delete);
    await confirmSsh(tester, h.api.reviews.single.target);
    expect(h.api.writes.length, 1);
  });
  testWidgets(
    'inventory refresh permanently expires review even if same object returns',
    (tester) async {
      final h = await pumpSsh(tester);
      await startSshReview(tester);
      h.container.invalidate(sshCredentialsInventoryProvider);
      await tester.pumpAndSettle();
      expect(find.text('Review expired'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('ssh-credential-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'session switch clears editor fields and old session cannot revive them',
    (tester) async {
      final h = await pumpSsh(tester);
      await tapSsh(tester, 'ssh-credentials-importKeyPair');
      await enterSsh(tester, 'ssh-credential-private-key', sshSyntheticPrivate);
      final controller = tester
          .widget<TextField>(
            find.byKey(const Key('ssh-credential-private-key')),
          )
          .controller!;
      h.select(null);
      await tester.pumpAndSettle();
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(find.text('SSH editor expired'), findsOneWidget);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'backgrounding clears private editor input and requires a new review',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final h = await pumpSsh(tester);
      await tapSsh(tester, 'ssh-credentials-importKeyPair');
      await enterSsh(tester, 'ssh-credential-private-key', sshSyntheticPrivate);
      final controller = tester
          .widget<TextField>(
            find.byKey(const Key('ssh-credential-private-key')),
          )
          .controller!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
      expect(find.text('SSH editor expired'), findsOneWidget);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'background during pending import review discards input and ignores its late result',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final pending = Completer<SshCredentialReview>();
      final api = SshFake()..onReview = (_) => pending.future;
      final h = await pumpSsh(tester, fake: api);
      await startSshReview(tester, importing: true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      pending.complete(
        SshCredentialReview(
          request: api.reviews.single,
          endpoint: sshEndpoint,
          warnings: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SshCredentialsReviewDialog), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('late review after changed connection cannot be confirmed', (
    tester,
  ) async {
    final pending = Completer<SshCredentialReview>();
    final api = SshFake()..onReview = (_) => pending.future;
    final h = await pumpSsh(tester, fake: api);
    await startSshReview(tester);
    h.select(h.newSession());
    pending.complete(
      SshCredentialReview(
        request: api.reviews.single,
        endpoint: sshEndpoint,
        warnings: [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SshCredentialsReviewDialog), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'unknown result disables workspace actions and cannot be refreshed away',
    (tester) async {
      final api = SshFake()
        ..onExecute = () async => const SshCredentialResult(
          SshCredentialOutcome.unknown,
          'Unverified',
        );
      final h = await pumpSsh(tester, fake: api);
      await startSshReview(tester);
      await confirmSsh(tester, 'GENERATE New identity');
      expect(
        h.container.read(sshCredentialsControllerProvider).unknown,
        isTrue,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('ssh-credentials-refresh')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('ssh-credentials-importKeyPair')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes.length, 1);
    },
  );
  for (final width in [320.0, 430.0]) {
    for (final kind in ['generate', 'import', 'connection']) {
      testWidgets(
        '$width px 200 percent keyboard: $kind editor and review stay usable',
        (tester) async {
          final h = await pumpSsh(
            tester,
            width: width,
            scale: 2,
            keyboard: 280,
          );
          expect(tester.takeException(), isNull);
          if (kind == 'connection') {
            await fillConnection(tester);
            await tapSsh(tester, 'ssh-credential-host-verified');
            await tapSsh(tester, 'ssh-credential-editor-review');
          } else {
            await startSshReview(tester, importing: kind == 'import');
          }
          expect(tester.takeException(), isNull);
          await confirmSsh(tester, h.api.reviews.single.target);
          expect(h.api.writes.length, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

class _SshRingCanvas implements Canvas {
  final colors = <Color>[];
  final sweeps = <double>[];
  @override
  void drawOval(Rect rect, Paint paint) {}
  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    colors.add(paint.color);
    sweeps.add(sweepAngle);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected chart painting operation');
}
