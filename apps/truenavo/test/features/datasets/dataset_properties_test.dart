import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/datasets/dataset_properties_controller.dart';
import 'package:truenavo/features/datasets/dataset_properties_page.dart';
import 'package:truenavo/features/datasets/dataset_size_input.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _endpoint = 'wss://nas.example/api/current';
DatasetPropertySnapshot _snapshot({
  String? blocked,
  List<String> descendants = const [],
  bool countKnown = true,
}) => DatasetPropertySnapshot(
  id: 'tank/media',
  guid: '1234',
  usedBytes: 1073741824,
  referencedBytes: 536870912,
  availableBytes: 10737418240,
  parentAvailableBytes: 10737418240,
  descendants: descendants,
  descendantCount: countKnown ? descendants.length : null,
  blockedReason: blocked,
  properties: {
    for (final key in datasetByteProperties)
      key: const DatasetPropertyValue(value: 0, source: 'DEFAULT'),
    'compression': const DatasetPropertyValue(
      value: 'LZ4',
      source: 'INHERITED',
      sourceDataset: 'tank',
    ),
    'atime': const DatasetPropertyValue(value: 'OFF', source: 'LOCAL'),
    'readonly': const DatasetPropertyValue(value: 'OFF', source: 'LOCAL'),
  },
  parentProperties: {
    'compression': const DatasetPropertyValue(value: 'ZSTD', source: 'LOCAL'),
    'atime': const DatasetPropertyValue(value: 'OFF', source: 'LOCAL'),
    'readonly': const DatasetPropertyValue(value: 'OFF', source: 'LOCAL'),
  },
);
AuthenticatedSession _session(_Api api, {String? endpoint = _endpoint}) =>
    AuthenticatedSession(
      profileId: 'nas',
      repository: api,
      availableMethodNames: const {},
      version: '25.10.1',
      endpoint: endpoint,
    );

void main() {
  test('controller sends exact reviewed request and releases shared lock on verified result', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    final request = h.request;
    await h.controller.apply(expectedSession: h.session, request: request);
    expect(h.api.requests.single, same(request));
    expect(h.state.result!.outcome, DatasetPropertyOutcome.verified);
    expect(h.state.server, _endpoint);
    expect(h.state.target, 'tank/media');
    expect(h.container.read(serverOperationLockProvider).acquire(), isNotNull);
  });
  test(
    'stale session, missing endpoint and invalid fields cannot reach API',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      await h.controller.apply(
        expectedSession: _session(h.api),
        request: h.request,
      );
      await h.controller.apply(
        expectedSession: h.session,
        request: DatasetPropertyUpdate(
          snapshot: h.api.snapshot,
          changes: {'quota': 4},
        ),
      );
      final noEndpoint = _session(h.api, endpoint: null);
      h.select(noEndpoint);
      await h.controller.apply(expectedSession: noEndpoint, request: h.request);
      expect(h.api.requests, isEmpty);
    },
  );
  test('shared operation lock blocks submission', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.container.read(serverOperationLockProvider).acquire();
    await h.controller.apply(expectedSession: h.session, request: h.request);
    expect(h.api.requests, isEmpty);
    expect(h.state.result!.outcome, DatasetPropertyOutcome.rejected);
  });
  test('unknown outcome keeps lock, has no automatic retry and cannot be acknowledged on same connection', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.api.result = const DatasetPropertyResult(
      outcome: DatasetPropertyOutcome.unknown,
      message: 'Inspect before retry.',
    );
    await h.controller.apply(expectedSession: h.session, request: h.request);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    h.controller.acknowledgeUnknown();
    expect(h.state.unresolved, isTrue);
    await h.controller.apply(expectedSession: h.session, request: h.request);
    expect(h.api.requests, hasLength(1));
    h.select(_session(_Api()));
    h.controller.acknowledgeUnknown();
    expect(h.state.unresolved, isFalse);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNotNull);
  });
  test(
    'connection replacement ignores old completion and keeps origin warning',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      final pending = Completer<DatasetPropertyResult>();
      h.api.pending = pending.future;
      final apply = h.controller.apply(
        expectedSession: h.session,
        request: h.request,
      );
      h.select(_session(_Api(), endpoint: 'wss://other.example/api/current'));
      pending.complete(h.api.result);
      await apply;
      expect(h.state.unresolved, isTrue);
      expect(h.state.server, _endpoint);
    },
  );
  test('unexpected exception becomes sanitized unknown', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.api.throwError = true;
    await h.controller.apply(expectedSession: h.session, request: h.request);
    expect(h.state.unresolved, isTrue);
    expect(h.state.result!.message, isNot(contains('private')));
  });
  test('double taps submit once and disposal does not write again', () async {
    final h = _Harness();
    final pending = Completer<DatasetPropertyResult>();
    h.api.pending = pending.future;
    final apply = h.controller.apply(
      expectedSession: h.session,
      request: h.request,
    );
    await h.controller.apply(expectedSession: h.session, request: h.request);
    expect(h.api.requests, hasLength(1));
    h.container.dispose();
    pending.complete(h.api.result);
    await apply;
    expect(h.api.requests, hasLength(1));
  });
  testWidgets('offline page does not query or expose editing', (tester) async {
    final api = _Api();
    await _pump(tester, api, connected: false);
    expect(find.text('Editor unavailable'), findsOneWidget);
    expect(api.reads, 0);
  });
  testWidgets(
    'inventory shows real bytes source and explicit native edit entry',
    (tester) async {
      final api = _Api();
      await _pump(tester, api);
      expect(find.text('tank/media'), findsOneWidget);
      expect(find.textContaining('1073741824 B'), findsOneWidget);
      expect(find.text('Edit properties'), findsOneWidget);
      expect(api.requests, isEmpty);
    },
  );
  testWidgets('unsupported dataset displays reason and disabled edit button', (
    tester,
  ) async {
    final api = _Api()
      ..snapshot = _snapshot(
        blocked: 'Encrypted dataset requires dedicated workflow.',
      );
    await _pump(tester, api);
    expect(find.textContaining('Encrypted dataset'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Edit properties'),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets('opening editor and canceling review send no update', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, api);
    await tester.tap(find.text('Edit properties'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('dataset-quota')),
      '2147483648',
    );
    await _scroll(tester, find.text('Review changes'), 500);
    await tester.tap(find.text('Review changes'));
    await tester.pumpAndSettle();
    expect(find.text('Review dataset changes'), findsOneWidget);
    expect(find.text('Before: 0 · DEFAULT'), findsOneWidget);
    expect(find.text('After: 2147483648 · LOCAL'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply properties'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.requests, isEmpty);
  });
  testWidgets(
    'byte validation rejects fractional and too-small quotas before review',
    (tester) async {
      final api = _Api();
      await _pump(tester, api, editor: true);
      for (final value in ['1.5', '5']) {
        await _scroll(
          tester,
          find.byKey(const ValueKey('dataset-quota')),
          -600,
        );
        await tester.enterText(
          find.byKey(const ValueKey('dataset-quota')),
          value,
        );
        FocusManager.instance.primaryFocus?.unfocus();
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        await _scroll(tester, find.text('Review changes'), 600);
        await tester.tap(find.text('Review changes'));
        await tester.pumpAndSettle();
        expect(find.text('Review dataset changes'), findsNothing);
        expect(
          find.textContaining(
            value == '1.5' ? 'Enter whole non-negative' : 'A quota must be 0',
          ),
          findsOneWidget,
        );
      }
      expect(api.requests, isEmpty);
    },
  );
  testWidgets(
    'review displays inheritance effective value and original source',
    (tester) async {
      final api = _Api();
      await _pump(
        tester,
        api,
        dialog: DatasetPropertyUpdate(
          snapshot: api.snapshot,
          changes: {'compression': 'INHERIT'},
        ),
      );
      expect(find.text('Before: LZ4 · INHERITED from tank'), findsOneWidget);
      expect(find.text('After: ZSTD · INHERIT from parent'), findsOneWidget);
      expect(find.text('Dataset GUID: 1234'), findsOneWidget);
    },
  );
  testWidgets(
    'explicit reviewed confirmation applies once and returns verified inventory',
    (tester) async {
      final api = _Api();
      await _pump(tester, api);
      await tester.tap(find.text('Edit properties'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('dataset-quota')),
        '2147483648',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _scroll(tester, find.text('Review changes'), 500);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply properties'));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));
      expect(api.requests.single.changes, {'quota': 2147483648});
      expect(find.text('Properties verified'), findsOneWidget);
    },
  );
  testWidgets(
    'untracked descendant count disables behavior but not byte fields',
    (tester) async {
      final api = _Api()..snapshot = _snapshot(countKnown: false);
      await _pump(tester, api, editor: true);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('dataset-quota')))
            .enabled,
        isTrue,
      );
      await _scroll(
        tester,
        find.byKey(const ValueKey('dataset-compression')),
        500,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('dataset-compression')),
            )
            .onChanged,
        isNull,
      );
      expect(
        find.textContaining('server must report filesystem_count 0'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'GiB input converts exactly and unit changes preserve the amount',
    (tester) async {
      final api = _Api();
      await _pump(tester, api, editor: true);
      final input = find.byKey(const ValueKey('dataset-quota'));
      final units = find.byKey(const ValueKey('dataset-quota-unit'));
      await tester.tap(units);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GiB').last);
      await tester.pumpAndSettle();
      await tester.enterText(input, '1.5');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(units);
      await tester.pumpAndSettle();
      await tester.tap(find.text('MiB').last);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '1536');
      expect(
        tester.widget<DropdownButton<DatasetSizeUnit>>(units).value,
        DatasetSizeUnit.mebibytes,
      );
      await _scroll(tester, find.text('Review changes'), 500);
      await tester.tap(find.text('Review changes'));
      await tester.pumpAndSettle();
      expect(find.text('After: 1610612736 · LOCAL'), findsOneWidget);
      expect(api.requests, isEmpty);
    },
  );
  testWidgets('invalid size cannot silently change the displayed unit', (
    tester,
  ) async {
    final api = _Api();
    await _pump(tester, api, editor: true);
    await tester.enterText(find.byKey(const ValueKey('dataset-quota')), '1.5');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final units = find.byKey(const ValueKey('dataset-quota-unit'));
    await tester.tap(units);
    await tester.pumpAndSettle();
    await tester.tap(find.text('GiB').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DropdownButton<DatasetSizeUnit>>(units).value,
      DatasetSizeUnit.bytes,
    );
    expect(api.requests, isEmpty);
  });
  for (final dark in [false, true]) {
    testWidgets(
      'editor and review fit 320px at 2x scale ${dark ? 'dark' : 'light'}',
      (tester) async {
        final api = _Api();
        await _pump(
          tester,
          api,
          editor: true,
          width: 320,
          scale: 2,
          dark: dark,
        );
        await _scroll(
          tester,
          find.byKey(const ValueKey('dataset-readonly')),
          400,
        );
        expect(tester.takeException(), isNull);
        await _pump(
          tester,
          api,
          dialog: DatasetPropertyUpdate(
            snapshot: api.snapshot,
            changes: {'compression': 'INHERIT', 'quota': 2147483648},
          ),
          width: 320,
          scale: 2,
          dark: dark,
        );
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, -900),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Cancel'), findsOneWidget);
      },
    );
  }
  testWidgets(
    'keyboard viewport remains scrollable with visible review action',
    (tester) async {
      final api = _Api();
      await _pump(tester, api, editor: true, width: 360);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.tap(find.byKey(const ValueKey('dataset-quota')));
      await tester.pumpAndSettle();
      await _scroll(tester, find.text('Review changes'), 400);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _scroll(WidgetTester tester, Finder target, double delta) =>
    tester.scrollUntilVisible(
      target,
      delta,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );

Future<void> _pump(
  WidgetTester tester,
  _Api api, {
  bool connected = true,
  bool editor = false,
  DatasetPropertyUpdate? dialog,
  double width = 440,
  double scale = 1,
  bool dark = true,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final session = _session(api);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardActiveSessionProvider.overrideWithValue(
          connected ? session : null,
        ),
      ],
      child: MaterialApp(
        theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: dialog != null
            ? Scaffold(
                body: DatasetPropertyReviewDialog(
                  server: _endpoint,
                  request: dialog,
                ),
              )
            : editor
            ? DatasetPropertyEditorPage(
                session: session,
                snapshot: api.snapshot,
              )
            : const DatasetPropertiesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Harness {
  _Harness() {
    session = _session(api);
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final api = _Api();
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  DatasetPropertiesController get controller =>
      container.read(datasetPropertiesControllerProvider.notifier);
  DatasetPropertiesState get state =>
      container.read(datasetPropertiesControllerProvider);
  DatasetPropertyUpdate get request => DatasetPropertyUpdate(
    snapshot: api.snapshot,
    changes: {'quota': 2147483648},
  );
  void select(AuthenticatedSession next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }
}

class _Api implements SessionRepository, AuthenticatedDatasetPropertiesSession {
  DatasetPropertySnapshot snapshot = _snapshot();
  int reads = 0;
  bool throwError = false;
  final requests = <DatasetPropertyUpdate>[];
  DatasetPropertyResult result = const DatasetPropertyResult(
    outcome: DatasetPropertyOutcome.verified,
    message: 'Verified.',
  );
  Future<DatasetPropertyResult>? pending;
  @override
  DatasetPropertiesCapabilities get datasetPropertiesCapabilities =>
      const DatasetPropertiesCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
      );
  @override
  Future<List<DatasetPropertySnapshot>> loadDatasetProperties() async {
    reads++;
    return [snapshot];
  }

  @override
  Future<DatasetPropertyResult> updateDatasetProperties(
    DatasetPropertyUpdate request,
  ) async {
    requests.add(request);
    if (throwError) throw StateError('private');
    return await pending ?? result;
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async => throw UnimplementedError();
}
