import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/email_settings/email_settings_controller.dart';
import 'package:truenavo/features/email_settings/email_settings_editor.dart';
import 'package:truenavo/features/email_settings/email_settings_page.dart';
import 'package:truenavo/features/email_settings/email_settings_review.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'email_settings_fakes.dart';

const newPassword = 'PRIVATE-EMAIL-PASSWORD';
Future<EmailHarness> pumpEmail(
  WidgetTester tester, {
  EmailFake? fake,
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
  final h = EmailHarness(fake: fake);
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
        theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const EmailSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapEmail(
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

Future<void> enterEmail(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> selectEmail(WidgetTester tester, String key, String value) async {
  final choice = switch (value) {
    'STARTTLS configured' => 'email-security-tls',
    'Implicit TLS configured' => 'email-security-ssl',
    'Keep saved password' => 'email-password-keep',
    'Replace with new password' => 'email-password-replace',
    'Clear saved password' => 'email-password-clear',
    _ => throw StateError('Unknown synthetic editor choice'),
  };
  await tapEmail(tester, choice);
}

Future<void> openEmailEditor(WidgetTester tester, String kind) async {
  if (kind == 'test') {
    await tapEmail(tester, 'email-test');
    await enterEmail(tester, 'email-recipient', 'recipient@example.test');
    return;
  }
  await tapEmail(tester, 'email-edit');
  await enterEmail(tester, 'email-from-name', 'Updated Alerts');
  if (kind == 'replace') {
    await selectEmail(
      tester,
      'email-password-action',
      'Replace with new password',
    );
    await enterEmail(tester, 'email-new-password', newPassword);
  }
  if (kind == 'clear') {
    await tapEmail(tester, 'email-auth');
    await enterEmail(tester, 'email-username', '');
    await selectEmail(tester, 'email-password-action', 'Clear saved password');
  }
}

Future<void> openEmailReview(
  WidgetTester tester,
  String kind, {
  bool settle = true,
}) async {
  await openEmailEditor(tester, kind);
  await tapEmail(tester, 'email-editor-review', settle: settle);
}

Future<void> consentEmail(
  WidgetTester tester,
  String target, {
  bool clear = false,
}) async {
  await enterEmail(tester, 'email-confirm-target', target);
  await tapEmail(tester, 'email-confirm-contact');
  await tapEmail(tester, 'email-confirm-impact');
  if (clear) await tapEmail(tester, 'email-confirm-clear');
}

void background(WidgetTester tester) {
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
  for (final kind in ['keep', 'test']) {
    testWidgets(
      '$kind supplemental review details expand inline without expiring consent',
      (tester) async {
        final h = await pumpEmail(tester, width: 320, scale: 2, keyboard: 220);
        await openEmailReview(tester, kind);
        const supplemental =
            'Synthetic review only. No actual SMTP configuration or transmission.';
        expect(find.text(supplemental), findsNothing);
        expect(find.text(emailSecurityWarning), findsOneWidget);
        expect(
          find.text(kind == 'test' ? emailTestWarning : emailQueueWarning),
          findsOneWidget,
        );
        final request = h.api.reviews.single;
        await consentEmail(tester, request.target);
        final details = find.text('Additional server / adapter details');
        Future<void> toggleDetails() async {
          await tester.ensureVisible(details);
          await tester.pumpAndSettle();
          await tester.tap(details);
          await tester.pumpAndSettle();
        }

        await toggleDetails();
        expect(find.text(supplemental), findsOneWidget);
        expect(find.text('Email review expired'), findsNothing);
        await toggleDetails();
        expect(find.text(supplemental), findsNothing);
        final submit = find.byKey(const Key('email-confirm-submit'));
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
        expect(h.api.reviews, hasLength(1));
        expect(h.api.executes, isEmpty);
        expect(h.api.checks, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'compact summary and neutral configuration badges never imply delivery or authenticate SMTP TLS',
    (tester) async {
      final h = await pumpEmail(tester, width: 430);
      expect(h.api.reads, 1);
      expect(h.api.reviews, isEmpty);
      expect(h.api.executes, isEmpty);
      expect(h.api.checks, isEmpty);
      expect(find.text('Saved SMTP configuration'), findsOneWidget);
      expect(find.text('STARTTLS configured'), findsOneWidget);
      expect(find.text('Password set — not shown'), findsOneWidget);
      expect(
        find.text(
          'Transport settings are not a certificate-verification guarantee.',
        ),
        findsOneWidget,
      );
      expect(find.text(emailHost), findsNothing);
      await tapEmail(tester, 'email-security-details');
      expect(find.text(emailSecurityWarning), findsOneWidget);
      expect(find.text(emailQueueWarning), findsOneWidget);
      await tapEmail(tester, 'email-readiness-details');
      expect(find.text(emailHost), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('disconnected page never reads or sends', (tester) async {
    final h = await pumpEmail(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('Email configuration unavailable'), findsOneWidget);
    expect(find.byKey(const Key('email-test')), findsNothing);
  });
  for (final entry in <String, EmailSettingsInventory>{
    'readonly': emailInventory(admin: false),
    'OAuth': emailInventory(oauth: true),
    'unknownpassword': emailInventory(passwordPresent: null),
    'HA': emailInventory(ha: true),
    'busy': emailInventory(jobs: true),
  }.entries) {
    testWidgets(
      '${entry.key} stays readable but disables SMTP edits and test',
      (tester) async {
        final h = await pumpEmail(
          tester,
          fake: EmailFake(inventory: entry.value),
        );
        expect(find.text('Saved SMTP configuration'), findsOneWidget);
        for (final key in ['email-edit', 'email-test']) {
          expect(
            tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
            isNull,
          );
        }
        expect(h.api.executes, isEmpty);
      },
    );
  }
  testWidgets(
    'PLAIN settings remain visible, test disabled, explicit TLS edit required',
    (tester) async {
      await pumpEmail(
        tester,
        fake: EmailFake(
          inventory: emailInventory(
            settings: const EmailSmtpSettings(
              fromEmail: 'nas@example.test',
              outgoingServer: 'smtp.example.test',
              username: 'user',
              security: EmailSecurity.plain,
            ),
          ),
        ),
      );
      expect(find.text('Plain SMTP — insecure'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('email-test')))
            .onPressed,
        isNull,
      );
      await tapEmail(tester, 'email-edit');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('email-editor-review')))
            .onPressed,
        isNull,
      );
      await selectEmail(tester, 'email-security', 'STARTTLS configured');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('email-editor-review')))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'failed read hides remote and secret details; retry is explicit',
    (tester) async {
      final fake = EmailFake()
        ..onLoad = () async => throw StateError(newPassword);
      final h = await pumpEmail(tester, fake: fake);
      expect(find.textContaining(newPassword), findsNothing);
      expect(
        find.text('Email configuration could not be verified'),
        findsOneWidget,
      );
      expect(h.api.reads, 1);
      fake.onLoad = null;
      await tapEmail(tester, 'email-retry');
      expect(h.api.reads, 2);
      expect(find.text('Saved SMTP configuration'), findsOneWidget);
    },
  );
  for (final kind in ['keep', 'replace', 'clear']) {
    testWidgets(
      '$kind SMTP configuration requires full target and all action consents, then hides stale inventory',
      (tester) async {
        final h = await pumpEmail(tester);
        await openEmailReview(tester, kind);
        expect(h.api.executes, isEmpty);
        expect(h.api.reviews.single.password.action.name, kind);
        expect(find.textContaining(newPassword), findsNothing);
        expect(find.text(emailSecurityWarning), findsOneWidget);
        expect(find.text(emailQueueWarning), findsOneWidget);
        await consentEmail(
          tester,
          '${h.api.reviews.single.target} ',
          clear: kind == 'clear',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('email-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        await enterEmail(
          tester,
          'email-confirm-target',
          h.api.reviews.single.target,
        );
        if (kind == 'clear') {
          await tapEmail(tester, 'email-confirm-clear');
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('email-confirm-submit')),
                )
                .onPressed,
            isNull,
          );
          await tapEmail(tester, 'email-confirm-clear');
        }
        await tapEmail(tester, 'email-confirm-submit');
        expect(h.api.executes, hasLength(1));
        expect(h.api.checks, isEmpty);
        expect(
          h.container.read(emailSettingsControllerProvider).status,
          EmailSettingsStatus.completed,
        );
        if (kind == 'replace') {
          expect(h.api.reviews.single.password.isDisposed, isTrue);
        }
        expect(find.text('Saved SMTP configuration'), findsNothing);
        expect(h.api.reads, 1);
        await tapEmail(tester, 'email-refresh-after-review');
        expect(h.api.reads, 2);
        expect(find.text('Saved SMTP configuration'), findsOneWidget);
      },
    );
  }
  testWidgets(
    'replacement editor never prefills, displays or retains the handed-off password',
    (tester) async {
      final h = await pumpEmail(tester);
      await tapEmail(tester, 'email-edit');
      expect(find.byKey(const Key('email-new-password')), findsNothing);
      await selectEmail(
        tester,
        'email-password-action',
        'Replace with new password',
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('email-new-password')),
      );
      expect(field.obscureText, isTrue);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.controller!.text, isEmpty);
      await enterEmail(tester, 'email-new-password', newPassword);
      await tapEmail(tester, 'email-editor-review');
      expect(field.controller!.text, isEmpty);
      expect(find.textContaining(newPassword), findsNothing);
      expect(h.api.reviews.single.password.isDisposed, isFalse);
      await tapEmail(tester, 'email-review-cancel');
      expect(h.api.reviews.single.password.isDisposed, isTrue);
      expect(h.api.executes, isEmpty);
    },
  );
  testWidgets(
    'switching password choice clears replacement immediately and auth disable is not implicit clear',
    (tester) async {
      await pumpEmail(tester);
      await openEmailEditor(tester, 'replace');
      final password = tester
          .widget<TextField>(find.byKey(const Key('email-new-password')))
          .controller!;
      await selectEmail(tester, 'email-password-action', 'Keep saved password');
      expect(password.text, isEmpty);
      await tapEmail(tester, 'email-auth');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('email-editor-review')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('requires explicit Clear'), findsWidgets);
      await selectEmail(
        tester,
        'email-password-action',
        'Clear saved password',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('email-editor-review')))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'retargeting with Keep explicitly discloses retained credentials and queued mail',
    (tester) async {
      final h = await pumpEmail(tester);
      await openEmailEditor(tester, 'keep');
      await enterEmail(tester, 'email-host', 'smtp-other.example.test');
      await tapEmail(tester, 'email-editor-review');
      expect(
        find.textContaining('retained credentials to the new server'),
        findsOneWidget,
      );
      expect(h.api.executes, isEmpty);
    },
  );
  testWidgets(
    'test has only one explicit recipient and saved config; pending means no delivery claim and no auto poll',
    (tester) async {
      final h = await pumpEmail(tester);
      await tapEmail(tester, 'email-test');
      expect(find.byKey(const Key('email-host')), findsNothing);
      expect(find.byKey(const Key('email-new-password')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('email-editor-review')))
            .onPressed,
        isNull,
      );
      await enterEmail(
        tester,
        'email-recipient',
        'one@example.test,two@example.test',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('email-editor-review')))
            .onPressed,
        isNull,
      );
      await enterEmail(tester, 'email-recipient', 'recipient@example.test');
      await tapEmail(tester, 'email-editor-review');
      expect(h.api.reviews.single.settings, isNull);
      expect(find.textContaining('NAS hostname/domain'), findsWidgets);
      expect(find.text('To: recipient@example.test'), findsOneWidget);
      await consentEmail(tester, h.api.reviews.single.target);
      await tapEmail(tester, 'email-confirm-impact');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('email-confirm-submit')))
            .onPressed,
        isNull,
      );
      await tapEmail(tester, 'email-confirm-impact');
      await tapEmail(tester, 'email-confirm-submit');
      expect(h.api.executes, hasLength(1));
      expect(
        h.container.read(emailSettingsControllerProvider).status,
        EmailSettingsStatus.pending,
      );
      expect(h.api.checks, isEmpty);
      await tester.pump(const Duration(minutes: 1));
      expect(h.api.checks, isEmpty);
      h.api.onCheck = (id, _) async => EmailSettingsResult(
        EmailSettingsOutcome.pending,
        'waiting',
        jobId: id,
      );
      await tapEmail(tester, 'email-check-job');
      expect(h.api.checks, [51]);
      expect(
        h.container.read(emailSettingsControllerProvider).status,
        EmailSettingsStatus.pending,
      );
      h.api.onCheck = null;
      await tapEmail(tester, 'email-check-job');
      expect(h.api.checks, [51, 51]);
      expect(
        find.text('SMTP job success — delivery unverified'),
        findsOneWidget,
      );
      expect(h.api.executes, hasLength(1));
      expect(
        h.container.read(emailSettingsControllerProvider).status,
        EmailSettingsStatus.completed,
      );
    },
  );
  for (final cause in ['session', 'background', 'route', 'cancel']) {
    for (final kind in ['replace', 'test']) {
      testWidgets(
        '$kind editor $cause clears the actual text controller, not just visible fields',
        (tester) async {
          final h = await pumpEmail(tester);
          await openEmailEditor(tester, kind);
          final field = tester
              .widget<TextField>(
                find.byKey(
                  Key(
                    kind == 'replace'
                        ? 'email-new-password'
                        : 'email-recipient',
                  ),
                ),
              )
              .controller!;
          expect(field.text, isNotEmpty);
          if (cause == 'session') h.select(h.newSession());
          if (cause == 'background') background(tester);
          if (cause == 'cancel') await tapEmail(tester, 'email-editor-cancel');
          if (cause == 'route') {
            final navigator = tester.state<NavigatorState>(
              find.byType(Navigator),
            );
            unawaited(
              navigator.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Other workspace')),
                ),
              ),
            );
          }
          await tester.pumpAndSettle();
          expect(field.text, isEmpty);
          expect(h.api.executes, isEmpty);
          expect(h.api.reviews, isEmpty);
          expect(find.textContaining(newPassword), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final cause in [
    'session',
    'background',
    'inventory',
    'route',
    'timeout',
  ]) {
    testWidgets(
      'review $cause destroys replacement capsule and hides private-input details',
      (tester) async {
        final h = await pumpEmail(tester);
        await openEmailReview(tester, 'replace');
        final password = h.api.reviews.single.password;
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background(tester);
        if (cause == 'inventory') {
          h.api.inventory = emailInventory();
          h.container.invalidate(emailSettingsInventoryProvider);
        }
        if (cause == 'route') {
          final navigator = tester.state<NavigatorState>(
            find.byType(Navigator),
          );
          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Other workspace')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          navigator.pop();
        }
        if (cause == 'timeout') await tester.pump(const Duration(minutes: 5));
        await tester.pumpAndSettle();
        expect(password.isDisposed, isTrue);
        expect(find.text('Email review expired'), findsOneWidget);
        expect(find.byKey(const Key('email-confirm-target')), findsNothing);
        expect(h.api.executes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final phase in ['review', 'execute', 'check']) {
    testWidgets(
      'another route during held $phase prevents late authorization or false completion',
      (tester) async {
        final h = await pumpEmail(tester),
            pendingReview = Completer<EmailSettingsReview>(),
            pendingExecute = Completer<void>(),
            pendingCheck = Completer<EmailSettingsResult>();
        if (phase == 'review') h.api.onReview = (_) => pendingReview.future;
        if (phase == 'execute') {
          h.api.onExecute = (_, current) async {
            await pendingExecute.future;
            if (current()) h.api.mutations++;
            return const EmailSettingsResult(
              EmailSettingsOutcome.rejected,
              'stale',
            );
          };
        }
        await openEmailReview(
          tester,
          phase == 'check' ? 'test' : 'replace',
          settle: phase != 'review',
        );
        if (phase != 'review') {
          await consentEmail(tester, h.api.reviews.single.target);
          await tapEmail(
            tester,
            'email-confirm-submit',
            settle: phase != 'execute',
          );
        }
        if (phase == 'check') {
          h.api.onCheck = (_, _) => pendingCheck.future;
          await tapEmail(tester, 'email-check-job', settle: false);
        }
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Other workspace')),
            ),
          ),
        );
        if (phase == 'review') {
          pendingReview.complete(
            EmailSettingsReview(
              request: h.api.reviews.single,
              endpoint: emailEndpoint,
              warnings: const [],
            ),
          );
        }
        if (phase == 'execute') pendingExecute.complete();
        if (phase == 'check') {
          pendingCheck.complete(
            const EmailSettingsResult(
              EmailSettingsOutcome.completed,
              'late',
              jobId: 51,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(h.api.mutations, phase == 'check' ? 1 : 0);
        expect(find.byType(EmailSettingsReviewDialog), findsNothing);
        if (phase != 'review') {
          expect(
            h.container.read(emailSettingsControllerProvider).status,
            EmailSettingsStatus.unknown,
          );
          expect(
            h.container.read(serverOperationLockProvider).acquire(),
            isNull,
          );
        }
        if (phase != 'check') {
          expect(h.api.reviews.single.password.isDisposed, isTrue);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'normal modal close preserves capsule across delayed review and delayed confirmed write',
    (tester) async {
      final h = await pumpEmail(tester),
          pendingReview = Completer<EmailSettingsReview>(),
          pendingExecute = Completer<void>();
      h.api.onReview = (_) => pendingReview.future;
      h.api.onExecute = (_, current) async {
        await pendingExecute.future;
        if (current()) h.api.mutations++;
        return const EmailSettingsResult(
          EmailSettingsOutcome.completed,
          'verified',
        );
      };
      await openEmailReview(tester, 'replace', settle: false);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(EmailSettingsEditorDialog), findsNothing);
      final password = h.api.reviews.single.password;
      expect(password.isDisposed, isFalse);
      pendingReview.complete(
        EmailSettingsReview(
          request: h.api.reviews.single,
          endpoint: emailEndpoint,
          warnings: const [],
        ),
      );
      await tester.pumpAndSettle();
      await consentEmail(tester, h.api.reviews.single.target);
      await tapEmail(tester, 'email-confirm-submit', settle: false);
      await tester.pump(const Duration(seconds: 1));
      expect(password.isDisposed, isFalse);
      pendingExecute.complete();
      await tester.pumpAndSettle();
      expect(password.isDisposed, isTrue);
      expect(h.api.mutations, 1);
      expect(
        h.container.read(emailSettingsControllerProvider).status,
        EmailSettingsStatus.completed,
      );
    },
  );
  testWidgets(
    'owned failure stays unknown, survives route removal and never resends',
    (tester) async {
      final h = await pumpEmail(tester);
      await openEmailReview(tester, 'test');
      await consentEmail(tester, h.api.reviews.single.target);
      await tapEmail(tester, 'email-confirm-submit');
      h.api.onCheck = (id, _) async => EmailSettingsResult(
        EmailSettingsOutcome.unknown,
        newPassword,
        jobId: id,
      );
      await tapEmail(tester, 'email-check-job');
      expect(
        h.container.read(emailSettingsControllerProvider).status,
        EmailSettingsStatus.unknown,
      );
      expect(find.textContaining(newPassword), findsNothing);
      expect(find.byKey(const Key('email-check-job')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      expect(h.api.executes, hasLength(1));
      expect(h.api.checks, [51]);
    },
  );
  testWidgets(
    'fresh same-host recovery uses explicit read then inspection ACK, never password or test replay',
    (tester) async {
      final fake = EmailFake()
        ..onExecute = (_, _) async =>
            const EmailSettingsResult(EmailSettingsOutcome.unknown, 'unknown');
      final h = await pumpEmail(tester, fake: fake);
      await openEmailReview(tester, 'replace');
      await consentEmail(tester, h.api.reviews.single.target);
      await tapEmail(tester, 'email-confirm-submit');
      expect(h.api.reviews.single.password.isDisposed, isTrue);
      h.select(h.newSession());
      await tester.pumpAndSettle();
      expect(h.api.reads, 1);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('email-acknowledge')))
            .onPressed,
        isNull,
      );
      await tapEmail(tester, 'email-verify-reconnected');
      expect(h.api.reads, 2);
      await tapEmail(tester, 'email-acknowledge');
      expect(h.container.read(emailSettingsControllerProvider).locked, isFalse);
      expect(
        find.textContaining('prior operation remains unverified'),
        findsOneWidget,
      );
      expect(h.api.executes, hasLength(1));
      expect(h.api.checks, isEmpty);
    },
  );
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'summary and expanded safety ${width.toInt()} ${dark ? 'dark' : 'light'} at 200 percent',
        (tester) async {
          await pumpEmail(tester, width: width, dark: dark, scale: 2);
          await tapEmail(tester, 'email-security-details');
          await tapEmail(tester, 'email-readiness-details');
          expect(tester.takeException(), isNull);
        },
      );
      for (final kind in ['keep', 'replace', 'clear', 'test']) {
        testWidgets(
          '$kind editor/review ${width.toInt()} ${dark ? 'dark' : 'light'} 200 percent with keyboard',
          (tester) async {
            final h = await pumpEmail(
              tester,
              width: width,
              dark: dark,
              scale: 2,
              keyboard: 300,
            );
            await openEmailReview(tester, kind);
            await consentEmail(
              tester,
              h.api.reviews.single.target,
              clear: kind == 'clear',
            );
            await tapEmail(tester, 'email-confirm-submit');
            expect(h.api.executes, hasLength(1));
            expect(
              h.container.read(emailSettingsControllerProvider).status,
              kind == 'test'
                  ? EmailSettingsStatus.pending
                  : EmailSettingsStatus.completed,
            );
            expect(find.textContaining(newPassword), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
