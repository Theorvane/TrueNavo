import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/dashboard/dashboard_layout.dart';
import 'package:truenavo/features/dashboard/dashboard_layout_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_layout_store.dart';
import 'package:truenavo/features/dashboard/dashboard_layout_store_io.dart';

final firstIdentity = DashboardLayoutIdentity.fromEndpoint(
  profileId: 'profile-a',
  endpoint: 'wss://nas.example/api/current',
)!;
final secondIdentity = DashboardLayoutIdentity.fromEndpoint(
  profileId: 'profile-b',
  endpoint: 'wss://other.example/api/current',
)!;

void main() {
  group('layout format and identity', () {
    test(
      'fresh defaults prioritize live metrics without changing saved v1 order',
      () {
        expect(DashboardLayout.defaults().order, [
          DashboardSection.metrics,
          DashboardSection.liveMetrics,
          DashboardSection.charts,
          DashboardSection.performanceHistory,
        ]);
        final old = DashboardLayout.decode(
          '{"version":1,"order":["metrics","charts","liveMetrics","performanceHistory"],"hidden":[]}',
        )!;
        expect(old.order, [
          DashboardSection.metrics,
          DashboardSection.charts,
          DashboardSection.liveMetrics,
          DashboardSection.performanceHistory,
        ]);
      },
    );
    test(
      'all sections default visible and immutable round-trip is lossless',
      () {
        final layout = DashboardLayout.defaults()
            .move(DashboardSection.liveMetrics, -1)
            .toggle(DashboardSection.metrics, false);
        final restored = DashboardLayout.decode(layout.encode())!;
        expect(restored.order, layout.order);
        expect(restored.hidden, {DashboardSection.metrics});
        expect(DashboardLayout.defaults().visible, DashboardSection.values);
        expect(
          () => restored.order.add(DashboardSection.charts),
          throwsUnsupportedError,
        );
        expect(
          () => restored.hidden.add(DashboardSection.charts),
          throwsUnsupportedError,
        );
      },
    );
    test('move boundaries and visibility changes retain order', () {
      final layout = DashboardLayout.defaults();
      expect(
        identical(layout.move(DashboardSection.metrics, -1), layout),
        isTrue,
      );
      expect(
        identical(layout.move(DashboardSection.performanceHistory, 1), layout),
        isTrue,
      );
      expect(
        layout
            .toggle(DashboardSection.metrics, false)
            .toggle(DashboardSection.metrics, true)
            .order,
        layout.order,
      );
      expect(
        () => DashboardLayout(order: [DashboardSection.metrics], hidden: {}),
        throwsArgumentError,
      );
    });
    test('older v1 layouts append new sections with default visibility', () {
      final old = DashboardLayout.decode(
        '{"version":1,"order":["charts","metrics"],"hidden":["metrics"]}',
      )!;
      expect(old.order, [
        DashboardSection.charts,
        DashboardSection.metrics,
        DashboardSection.liveMetrics,
        DashboardSection.performanceHistory,
      ]);
      expect(old.hidden, {DashboardSection.metrics});
    });
    for (final raw in <String>[
      '',
      'null',
      '[]',
      '{broken',
      '{"version":2,"order":["metrics"],"hidden":[]}',
      '{"version":1,"order":[],"hidden":[]}',
      '{"version":1,"order":["metrics","metrics"],"hidden":[]}',
      '{"version":1,"order":["missing"],"hidden":[]}',
      '{"version":1,"order":[2],"hidden":[]}',
      '{"version":1,"order":["metrics"],"hidden":["charts"]}',
      '{"version":1,"order":["metrics"],"hidden":["metrics","metrics"]}',
      '{"version":1,"order":["metrics"],"hidden":[],"extra":"ignored?"}',
      'x' * 8193,
    ].indexed) {
      test(
        'malformed payload ${raw.$1} is not applied',
        () => expect(DashboardLayout.decode(raw.$2), isNull),
      );
    }
    test('identity is opaque, stable and isolated by profile and endpoint', () {
      expect(firstIdentity.storageKey, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(firstIdentity.storageKey, isNot(contains('nas.example')));
      expect(
        firstIdentity,
        DashboardLayoutIdentity.fromEndpoint(
          profileId: 'profile-a',
          endpoint: 'wss://nas.example/api/current',
        ),
      );
      expect(
        firstIdentity,
        isNot(
          DashboardLayoutIdentity.fromEndpoint(
            profileId: 'profile-a',
            endpoint: 'wss://other.example/api/current',
          ),
        ),
      );
      expect(
        firstIdentity,
        isNot(
          DashboardLayoutIdentity.fromEndpoint(
            profileId: 'profile-b',
            endpoint: 'wss://nas.example/api/current',
          ),
        ),
      );
    });
    test(
      'credential-bearing and invalid endpoints cannot become identities',
      () {
        for (final endpoint in [
          null,
          '',
          '/relative',
          'file:///tmp',
          'wss://user:password@nas.example/api/current',
          'wss://nas.example/api/current?token=secret',
          'wss://nas.example/api/current#secret',
          'wss://nas.example/\u0000',
        ]) {
          expect(
            DashboardLayoutIdentity.fromEndpoint(
              profileId: 'profile-a',
              endpoint: endpoint,
            ),
            isNull,
          );
        }
        expect(
          DashboardLayoutIdentity.fromEndpoint(
            profileId: '',
            endpoint: 'wss://nas.example/api/current',
          ),
          isNull,
        );
      },
    );
  });
  group('file persistence', () {
    late Directory directory;
    late FileDashboardLayoutStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'truenavo-layout-test-',
      );
      store = FileDashboardLayoutStore(
        directory: () async => Directory('${directory.path}/layouts'),
      );
    });
    tearDown(() async => directory.delete(recursive: true));
    test(
      'survives recreation and atomically replaces existing files',
      () async {
        expect(await store.read(firstIdentity.storageKey), isNull);
        await store.write(
          firstIdentity.storageKey,
          DashboardLayout.defaults().encode(),
        );
        final changed = DashboardLayout.defaults().toggle(
          DashboardSection.charts,
          false,
        );
        await store.write(firstIdentity.storageKey, changed.encode());
        final reopened = FileDashboardLayoutStore(
          directory: () async => Directory('${directory.path}/layouts'),
        );
        expect(await reopened.read(firstIdentity.storageKey), changed.encode());
        expect(await store.read(secondIdentity.storageKey), isNull);
        expect(await Directory('${directory.path}/layouts').list().length, 1);
      },
    );
    test('rejects traversal and bounds external oversized files', () async {
      await expectLater(store.read('../secret'), throwsArgumentError);
      await expectLater(store.write('../secret', '{}'), throwsArgumentError);
      await expectLater(
        store.write(firstIdentity.storageKey, 'x' * 8193),
        throwsFormatException,
      );
      await Directory('${directory.path}/layouts').create();
      await File('${directory.path}/layouts/${firstIdentity.storageKey}.json')
          .writeAsString('x' * 10000);
      await expectLater(
        store.read(firstIdentity.storageKey),
        throwsFormatException,
      );
    });
    test('rejects invalid UTF-8 and reports directory failures', () async {
      await Directory('${directory.path}/layouts').create();
      await File('${directory.path}/layouts/${firstIdentity.storageKey}.json')
          .writeAsBytes([0xff]);
      await expectLater(
        store.read(firstIdentity.storageKey),
        throwsFormatException,
      );
      final unavailable = FileDashboardLayoutStore(
        directory: () async => throw FileSystemException('unavailable'),
      );
      await expectLater(
        unavailable.read(firstIdentity.storageKey),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
  group('layout state', () {
    late MemoryLayoutStore store;
    late ProviderContainer container;
    setUp(() {
      store = MemoryLayoutStore();
      container = ProviderContainer(
        overrides: [
          dashboardLayoutStoreProvider.overrideWithValue(store),
          dashboardLayoutIdentityProvider.overrideWith(
            (ref) => ref.watch(testIdentityProvider),
          ),
        ],
      );
      container.listen(
        dashboardLayoutControllerProvider(firstIdentity),
        (_, _) {},
      );
    });
    tearDown(() => container.dispose());
    test('loads, saves and resets persisted order and visibility', () async {
      await settleLayout();
      final notifier = container.read(
        dashboardLayoutControllerProvider(firstIdentity).notifier,
      );
      final edited = DashboardLayout.defaults()
          .toggle(DashboardSection.charts, false)
          .move(DashboardSection.liveMetrics, -1);
      expect(await notifier.save(edited), isTrue);
      expect(
        container
            .read(dashboardLayoutControllerProvider(firstIdentity))
            .layout
            .hidden,
        {DashboardSection.charts},
      );
      expect(
        DashboardLayout.decode(store.values[firstIdentity.storageKey]!)!.order,
        edited.order,
      );
      expect(await notifier.reset(), isTrue);
      expect(
        container
            .read(dashboardLayoutControllerProvider(firstIdentity))
            .layout
            .hidden,
        isEmpty,
      );
      expect(
        container
            .read(dashboardLayoutControllerProvider(firstIdentity))
            .layout
            .order,
        DashboardSection.values,
      );
    });
    test('malformed persistence uses defaults and explicit message', () async {
      store.values[firstIdentity.storageKey] = '{bad';
      await settleLayout();
      final state = container.read(
        dashboardLayoutControllerProvider(firstIdentity),
      );
      expect(state.layout.visible, DashboardSection.values);
      expect(state.message, contains('could not be read'));
      expect(store.writes, 0);
    });
    test(
      'read and write errors are sanitized without optimistic saving',
      () async {
        store.failRead = true;
        await settleLayout();
        expect(
          container
              .read(dashboardLayoutControllerProvider(firstIdentity))
              .message,
          contains('unavailable'),
        );
        store.failWrite = true;
        final result = await container
            .read(dashboardLayoutControllerProvider(firstIdentity).notifier)
            .save(
              DashboardLayout.defaults().toggle(DashboardSection.charts, false),
            );
        expect(result, isFalse);
        expect(
          container
              .read(dashboardLayoutControllerProvider(firstIdentity))
              .layout
              .hidden,
          isEmpty,
        );
        expect(
          container
              .read(dashboardLayoutControllerProvider(firstIdentity))
              .message,
          isNot(contains('secret')),
        );
      },
    );
    test(
      'server switches isolate preferences and reject stale editors',
      () async {
        await settleLayout();
        final old = container.read(
          dashboardLayoutControllerProvider(firstIdentity).notifier,
        );
        await old.save(
          DashboardLayout.defaults().toggle(DashboardSection.charts, false),
        );
        container.read(testIdentityProvider.notifier).select(secondIdentity);
        container.listen(
          dashboardLayoutControllerProvider(secondIdentity),
          (_, _) {},
        );
        await settleLayout();
        expect(
          container
              .read(dashboardLayoutControllerProvider(secondIdentity))
              .layout
              .hidden,
          isEmpty,
        );
        expect(await old.reset(), isFalse);
        await container
            .read(dashboardLayoutControllerProvider(secondIdentity).notifier)
            .save(
              DashboardLayout.defaults().toggle(
                DashboardSection.metrics,
                false,
              ),
            );
        expect(
          DashboardLayout.decode(store.values[firstIdentity.storageKey]!)!
              .hidden,
          {DashboardSection.charts},
        );
        expect(
          DashboardLayout.decode(store.values[secondIdentity.storageKey]!)!
              .hidden,
          {DashboardSection.metrics},
        );
      },
    );
    test(
      'concurrent saves refused and first commit remains authoritative',
      () async {
        await settleLayout();
        store.writeGate = Completer<void>();
        final notifier = container.read(
          dashboardLayoutControllerProvider(firstIdentity).notifier,
        );
        final firstSave = notifier.save(
          DashboardLayout.defaults().toggle(DashboardSection.charts, false),
        );
        expect(await notifier.reset(), isFalse);
        store.writeGate!.complete();
        expect(await firstSave, isTrue);
        expect(
          container
              .read(dashboardLayoutControllerProvider(firstIdentity))
              .layout
              .hidden,
          {DashboardSection.charts},
        );
      },
    );
    test('loading refuses writes and disposed loads cannot publish', () async {
      store.readGate = Completer<void>();
      final notifier = container.read(
        dashboardLayoutControllerProvider(firstIdentity).notifier,
      );
      expect(await notifier.reset(), isFalse);
      await Future<void>.delayed(Duration.zero);
      container.invalidate(dashboardLayoutControllerProvider(firstIdentity));
      store.readGate!.complete();
      await settleLayout();
      expect(store.writes, 0);
    });
  });
}

Future<void> settleLayout() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final testIdentityProvider =
    NotifierProvider<TestIdentity, DashboardLayoutIdentity?>(TestIdentity.new);

class TestIdentity extends Notifier<DashboardLayoutIdentity?> {
  @override
  DashboardLayoutIdentity? build() => firstIdentity;
  void select(DashboardLayoutIdentity? identity) => state = identity;
}

class MemoryLayoutStore implements DashboardLayoutStore {
  final values = <String, String>{};
  var failRead = false;
  var failWrite = false;
  var writes = 0;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  @override
  Future<String?> read(String key) async {
    await readGate?.future;
    if (failRead) throw StateError('secret storage details');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await writeGate?.future;
    if (failWrite) throw StateError('secret storage details');
    writes++;
    values[key] = value;
  }
}
