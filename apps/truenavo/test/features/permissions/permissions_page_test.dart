import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/sample/permissions_preview.dart';
import 'package:truenavo/features/permissions/permissions_acl_editor.dart';
import 'package:truenavo/features/permissions/permissions_controller.dart';
import 'package:truenavo/features/permissions/permissions_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'permissions_fakes.dart';

Future<PermissionsHarness> pumpPermissions(
  WidgetTester tester, {
  PermissionsFake? fake,
  bool editor = false,
  bool light = false,
  double scale = 1,
  double? width,
  int autoPolls = 0,
}) async {
  final h = PermissionsHarness(fake: fake, autoPolls: autoPolls);
  addTearDown(h.dispose);
  if (width != null) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 780);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
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
        home: editor
            ? PermissionsEditorPage(
                dataset: h.api.review.dataset,
                expectedSession: h.session,
              )
            : const PermissionsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      400,
      maxScrolls: 80,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapPermission(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> changeNfs(WidgetTester tester) async =>
    tapPermission(tester, 'permissions-bit-WRITE_DATA');
Future<void> reviewPermission(WidgetTester tester) async =>
    tapPermission(tester, 'permissions-review');
Future<void> fillConfirmation(
  WidgetTester tester, {
  String path = '/mnt/tank/media',
}) async {
  final field = find.byKey(const Key('permissions-confirm-path'));
  await reveal(tester, field);
  await tester.enterText(field, path);
  await tester.pumpAndSettle();
  await tapPermission(tester, 'permissions-confirm-risk');
}

void main() {
  testWidgets(
    'dataset discovery is read-only and opens the exact dataset root',
    (tester) async {
      final h = await pumpPermissions(tester);
      expect(find.text('tank/media'), findsOneWidget);
      expect(h.api.reads, 1);
      expect(h.api.writes, isEmpty);
      await tapPermission(tester, 'permissions-open-tank/media');
      expect(h.api.reviewReads, 1);
      expect(find.text('/mnt/tank/media'), findsOneWidget);
      expect(find.textContaining('Owner UID 3000'), findsOneWidget);
    },
  );
  testWidgets('missing setter keeps inspection but disables mutation', (
    tester,
  ) async {
    final h = await pumpPermissions(
      tester,
      editor: true,
      fake: PermissionsFake(
        methods: permissionsMethods.difference({'filesystem.setacl'}),
      ),
    );
    await reveal(tester, find.byKey(const Key('permissions-review')));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('permissions-review')))
          .onPressed,
      isNull,
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets('read failures hide remote details and support explicit retry', (
    tester,
  ) async {
    final api = PermissionsFake();
    api.onLoad = () => Future.error(StateError('private token'));
    final h = await pumpPermissions(tester, fake: api);
    expect(find.textContaining('private token'), findsNothing);
    expect(find.text('Could not load permissions'), findsOneWidget);
    api.onLoad = () async => [permissionDataset];
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('tank/media'), findsOneWidget);
    expect(h.api.reads, 2);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('unchanged ACL validation does not open confirmation or send', (
    tester,
  ) async {
    final h = await pumpPermissions(tester, editor: true);
    await reviewPermission(tester);
    expect(find.text('Select an ACL change.'), findsOneWidget);
    expect(find.byType(PermissionsReviewDialog), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('review shows before/after and cancel sends nothing', (
    tester,
  ) async {
    final h = await pumpPermissions(tester, editor: true);
    await changeNfs(tester);
    await reviewPermission(tester);
    expect(find.byType(PermissionsReviewDialog), findsOneWidget);
    expect(find.text('Before'), findsOneWidget);
    expect(find.text('After'), findsOneWidget);
    expect(find.text('wss://sample.example/api/current'), findsWidgets);
    expect(h.api.writes, isEmpty);
    await tapPermission(tester, 'permissions-cancel-confirm');
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'exact path and risk acknowledgement required before one setter',
    (tester) async {
      final h = await pumpPermissions(tester, editor: true);
      await changeNfs(tester);
      await reviewPermission(tester);
      final button = find.byKey(const Key('permissions-apply-confirm'));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await fillConfirmation(tester, path: '/mnt/tank/media ');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('permissions-confirm-path')),
        '/mnt/tank/media',
      );
      await tester.pumpAndSettle();
      await tapPermission(tester, 'permissions-apply-confirm');
      expect(h.api.writes.length, 1);
      final request = h.api.writes.single;
      expect(request.acl!.first.permissions['WRITE_DATA'], isFalse);
      expect(request.acl!.first.flags['FILE_INHERIT'], isTrue);
      expect(request.acl!.map((ace) => ace.tag), [
        'owner@',
        'GROUP',
        'everyone@',
      ]);
      expect(request.review.uid, 3000);
      expect(request.review.gid, 3010);
      expect(request.mode, isNull);
    },
  );
  testWidgets(
    'session switch immediately hides ACL and review and sends nothing',
    (tester) async {
      final h = await pumpPermissions(tester, editor: true);
      await changeNfs(tester);
      await reviewPermission(tester);
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('permissions-confirm-path')), findsNothing);
      expect(find.text('/mnt/tank/media'), findsNothing);
      expect(find.byType(PermissionsAclEditor), findsNothing);
      expect(find.byKey(const Key('permissions-apply-confirm')), findsNothing);
      expect(h.api.writes, isEmpty);
      await tapPermission(tester, 'permissions-cancel-confirm');
      expect(find.text('Connection changed'), findsOneWidget);
    },
  );
  testWidgets(
    'session change hides prior inventory while new read is pending',
    (tester) async {
      final h = await pumpPermissions(tester);
      final next = PermissionsFake();
      final pending = Completer<List<PermissionDataset>>();
      next.onLoad = () => pending.future;
      h.select(
        h.newSession(fake: next, endpoint: 'wss://other.example/api/current'),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('tank/media'), findsNothing);
      pending.complete([]);
      await tester.pumpAndSettle();
      expect(
        find.text('No accessible dataset roots were returned.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'NFS entry reorder keeps explicit permission maps and selected principal',
    (tester) async {
      final h = await pumpPermissions(tester, editor: true);
      await tapPermission(tester, 'permissions-select-ace-1');
      await tapPermission(tester, 'permissions-ace-up');
      await reviewPermission(tester);
      await fillConfirmation(tester);
      await tapPermission(tester, 'permissions-apply-confirm');
      expect(h.api.writes.single.acl!.map((entry) => entry.tag), [
        'GROUP',
        'owner@',
        'everyone@',
      ]);
      expect(
        h.api.writes.single.acl!.first.permissions,
        h.api.review.acl[1].permissions,
      );
    },
  );
  testWidgets('local numeric identity must be resolved before it is selected', (
    tester,
  ) async {
    final h = await pumpPermissions(tester, editor: true);
    await tapPermission(tester, 'permissions-select-ace-1');
    final field = find.byKey(const Key('permissions-identity-id'));
    await reveal(tester, field);
    await tester.enterText(field, '3050');
    await tapPermission(tester, 'permissions-resolve-identity');
    expect(h.api.lookups, 1);
    expect(
      find.textContaining('Selected: Resolved local identity'),
      findsOneWidget,
    );
    await reviewPermission(tester);
    await fillConfirmation(tester);
    await tapPermission(tester, 'permissions-apply-confirm');
    expect(h.api.writes.single.acl![1].id, 3050);
  });
  testWidgets(
    'failed identity lookup preserves current principal and never applies typed ID',
    (tester) async {
      final api = PermissionsFake();
      api.onLookup = (_, _) async => null;
      final h = await pumpPermissions(tester, editor: true, fake: api);
      await tapPermission(tester, 'permissions-select-ace-1');
      await reveal(tester, find.byKey(const Key('permissions-identity-id')));
      await tester.enterText(
        find.byKey(const Key('permissions-identity-id')),
        '9999',
      );
      await tapPermission(tester, 'permissions-resolve-identity');
      expect(
        find.textContaining('could not be verified as a local principal'),
        findsOneWidget,
      );
      await reviewPermission(tester);
      expect(find.text('Select an ACL change.'), findsOneWidget);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'POSIX default list is not silently normalized and missing required entries block apply',
    (tester) async {
      final h = await pumpPermissions(
        tester,
        editor: true,
        fake: PermissionsFake(
          review: permissionReview(type: PermissionAclType.posix1e),
        ),
      );
      await tapPermission(tester, 'permissions-default-ace');
      await reviewPermission(tester);
      expect(
        find.textContaining('requires owner, owning group and other entries'),
        findsOneWidget,
      );
      expect(h.api.writes, isEmpty);
      expect(find.byType(PermissionsReviewDialog), findsNothing);
    },
  );
  testWidgets(
    'trivial POSIX mode is explicit separate action; recursive and strip remain disabled',
    (tester) async {
      final h = await pumpPermissions(
        tester,
        editor: true,
        fake: PermissionsFake(
          review: permissionReview(
            type: PermissionAclType.posix1e,
            trivial: true,
          ),
        ),
      );
      await tapPermission(tester, 'permissions-edit-mode');
      await reveal(tester, find.byKey(const Key('permissions-mode')));
      await tester.enterText(find.byKey(const Key('permissions-mode')), '700');
      await reviewPermission(tester);
      await fillConfirmation(tester);
      await tapPermission(tester, 'permissions-apply-confirm');
      expect(h.api.writes.single.mode, '700');
      expect(h.api.writes.single.acl, isNull);
      await reveal(tester, find.text('Apply recursively'));
      for (final title in ['Apply recursively', 'Strip ACL']) {
        final tile = find.ancestor(
          of: find.text(title),
          matching: find.byType(CheckboxListTile),
        );
        expect(tester.widget<CheckboxListTile>(tile).onChanged, isNull);
        expect(tester.widget<CheckboxListTile>(tile).value, isFalse);
      }
    },
  );
  testWidgets(
    'automatic read-only checks stop at configured bound without setter replay',
    (tester) async {
      final api = PermissionsFake();
      api.onApply = () async => const PermissionOperationResult(
        outcome: PermissionOperationOutcome.pending,
        jobId: 61,
      );
      final h = await pumpPermissions(tester, fake: api, autoPolls: 2);
      await h.container
          .read(permissionsControllerProvider.notifier)
          .apply(
            expectedSession: h.session,
            request: permissionChange(api.review),
            confirmation: permissionDataset.mountpoint,
          );
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();
      expect(api.checks, 2);
      expect(api.writes.length, 1);
      expect(
        h.container.read(permissionsControllerProvider).message,
        contains('paused'),
      );
    },
  );
  testWidgets('new session reusing a repository still reloads inventory', (
    tester,
  ) async {
    final h = await pumpPermissions(tester);
    expect(h.api.reads, 1);
    h.select(h.newSession());
    await tester.pumpAndSettle();
    expect(h.api.reads, 2);
  });
  testWidgets(
    'uncertain origin remains visible but old dataset inventory is hidden',
    (tester) async {
      final api = PermissionsFake();
      api.onApply = () async => const PermissionOperationResult(
        outcome: PermissionOperationOutcome.unknown,
      );
      final h = await pumpPermissions(tester, fake: api);
      await h.container
          .read(permissionsControllerProvider.notifier)
          .apply(
            expectedSession: h.session,
            request: permissionChange(api.review),
            confirmation: permissionDataset.mountpoint,
          );
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      await tester.pumpAndSettle();
      expect(
        find.text('Original server: wss://sample.example/api/current'),
        findsOneWidget,
      );
      expect(find.text('Original target: /mnt/tank/media'), findsOneWidget);
      expect(
        find.byKey(const Key('permissions-open-tank/media')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('permissions-reconnect-release')),
        findsNothing,
      );
      h.select(h.newSession());
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.byKey(const Key('permissions-reconnect-release')),
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('permissions-reconnect-release')),
            )
            .onPressed,
        isNull,
      );
      await tapPermission(tester, 'permissions-reconnect-ack');
      await tapPermission(tester, 'permissions-reconnect-release');
      expect(h.container.read(permissionsControllerProvider).locked, isFalse);
      expect(
        find.textContaining('Prior completion remains unverified'),
        findsOneWidget,
      );
      expect(api.writes.length, 1);
    },
  );
  testWidgets('late identity lookup is ignored after session change', (
    tester,
  ) async {
    final api = PermissionsFake();
    final result = Completer<PermissionIdentity?>();
    api.onLookup = (_, _) => result.future;
    final h = await pumpPermissions(tester, editor: true, fake: api);
    await tapPermission(tester, 'permissions-select-ace-1');
    await reveal(tester, find.byKey(const Key('permissions-identity-id')));
    await tester.enterText(
      find.byKey(const Key('permissions-identity-id')),
      '3050',
    );
    await reveal(tester, find.byKey(const Key('permissions-resolve-identity')));
    await tester.tap(find.byKey(const Key('permissions-resolve-identity')));
    await tester.pump();
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    await tester.pumpAndSettle();
    result.complete(
      const PermissionIdentity(
        kind: PermissionIdentityKind.group,
        id: 3050,
        name: 'Private prior identity',
        local: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Private prior identity'), findsNothing);
    expect(find.byType(PermissionsAclEditor), findsNothing);
    expect(api.writes, isEmpty);
  });
  testWidgets(
    'NFS advanced controls at 320px and 200% preserve flags and inherited marker',
    (tester) async {
      final h = await pumpPermissions(
        tester,
        editor: true,
        width: 320,
        scale: 2,
      );
      await tapPermission(tester, 'permissions-select-ace-1');
      await reveal(tester, find.byKey(const Key('permissions-ace-type')));
      await tester.tap(find.byKey(const Key('permissions-ace-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deny selected permissions').last);
      await tester.pumpAndSettle();
      await tapPermission(tester, 'permissions-flag-DIRECTORY_INHERIT');
      await reveal(tester, find.byKey(const Key('permissions-flag-INHERITED')));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('permissions-flag-INHERITED')),
            )
            .onChanged,
        isNull,
      );
      await reviewPermission(tester);
      await fillConfirmation(tester);
      await tapPermission(tester, 'permissions-apply-confirm');
      final entry = h.api.writes.single.acl![1];
      expect(entry.type, 'DENY');
      expect(entry.flags['DIRECTORY_INHERIT'], isTrue);
      expect(entry.flags['INHERITED'], isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  for (final light in [false, true]) {
    testWidgets(
      '320px at 200% text ${light ? 'light' : 'dark'} supports editor, keyboard and review',
      (tester) async {
        final h = await pumpPermissions(
          tester,
          editor: true,
          width: 320,
          scale: 2,
          light: light,
          fake: PermissionsFake(
            review: permissionReview(
              type: PermissionAclType.disabled,
              trivial: true,
            ),
          ),
        );
        await reveal(tester, find.byKey(const Key('permissions-mode')));
        await tester.enterText(
          find.byKey(const Key('permissions-mode')),
          '700',
        );
        await reviewPermission(tester);
        await fillConfirmation(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 250);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await reveal(
          tester,
          find.byKey(const Key('permissions-apply-confirm')),
        );
        expect(tester.takeException(), isNull);
        await tapPermission(tester, 'permissions-cancel-confirm');
        expect(h.api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  test('const connector-free preview supports NFS, POSIX, mode and rejects all setters', () async {
    const preview = _Preview();
    final datasets = await preview.loadPermissionDatasets();
    final types = <PermissionAclType>{};
    for (final dataset in datasets) {
      final review = await preview.loadPermissionReview(dataset);
      types.add(review.aclType);
      await expectLater(
        preview.applyPermissions(
          PermissionApplyRequest(review: review, acl: review.acl),
        ),
        throwsA(isA<PermissionsException>()),
      );
    }
    expect(types, containsAll(PermissionAclType.values));
    expect(
      (await preview.lookupPermissionIdentity(
        PermissionIdentityKind.user,
        3000,
      ))?.name,
      'media',
    );
    expect(
      await preview.lookupPermissionIdentity(
        PermissionIdentityKind.group,
        99999,
      ),
      isNull,
    );
    expect(
      (await preview.checkPermissionOperation(
        const PermissionOperationResult(
          outcome: PermissionOperationOutcome.pending,
          jobId: 2,
        ),
      )).outcome,
      PermissionOperationOutcome.unknown,
    );
  });
}

class _Preview with PermissionsPreviewAdapter {
  const _Preview();
}
