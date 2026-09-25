import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/dashboard/live_metrics.dart';
import 'package:trueraid/features/dashboard/live_metrics_controller.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

final time = DateTime.utc(2026, 9, 12, 12);

void main() {
  test(
    'start receives actual samples and retains a bounded immutable window',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.controller.start();
      for (var i = 0; i < 80; i++) {
        h.api.feed.emit(sample(i, usage: i.toDouble()));
      }
      expect(h.state.phase, LiveMetricsPhase.live);
      expect(h.state.samples, hasLength(60));
      expect(h.state.samples.first.cpu['cpu']!.usage, 20);
      expect(() => h.state.samples.clear(), throwsUnsupportedError);
      expect(h.state.endpoint, 'wss://nas.example/api/current');
    },
  );
  test('repeated starts never overlap subscriptions', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.controller.start();
    await h.controller.start();
    expect(h.api.opens, 1);
  });
  test('pause removes stale measurements and cancels source', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.controller.start();
    h.api.feed.emit(sample(0));
    h.controller.pause();
    await pump();
    expect(h.state.phase, LiveMetricsPhase.paused);
    expect(h.state.samples, isEmpty);
    expect(h.api.feed.closed, isTrue);
  });
  test('resume creates a new receipt window', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.controller.start();
    h.api.feed.emit(sample(0));
    h.controller.pause();
    await pump();
    h.api.feed = FakeFeed();
    await h.controller.start();
    h.api.feed.emit(sample(10));
    expect(h.api.opens, 2);
    expect(h.state.samples, hasLength(1));
  });
  test('failure sanitizes errors and does not auto-retry', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.controller.start();
    h.api.feed.emit(sample(0));
    h.api.feed.events.addError(StateError('secret remote payload'));
    await pump();
    expect(h.state.phase, LiveMetricsPhase.unavailable);
    expect(h.state.samples, isEmpty);
    expect(h.state.message, isNot(contains('secret')));
    expect(h.api.opens, 1);
  });
  test('unexpected source completion clears live badge', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.controller.start();
    h.api.feed.emit(sample(0));
    await h.api.feed.close();
    await pump();
    expect(h.state.phase, LiveMetricsPhase.unavailable);
  });
  test(
    'session change discards all old measurements and closes old feed',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.controller.start();
      h.api.feed.emit(sample(0));
      h.active = null;
      h.container.invalidate(dashboardActiveSessionProvider);
      h.container.read(dashboardActiveSessionProvider);
      await pump();
      expect(h.state.samples, isEmpty);
      expect(h.api.feed.closed, isTrue);
    },
  );
  test('new account on same endpoint never reuses old samples', () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.controller.start();
    h.api.feed.emit(sample(0));
    final replacement = FakeApi();
    h.active = session(replacement);
    h.container.invalidate(dashboardActiveSessionProvider);
    h.container.read(dashboardActiveSessionProvider);
    await pump();
    expect(h.state.samples, isEmpty);
    expect(h.api.feed.closed, isTrue);
    replacement.feed.emit(sample(8));
    expect(h.state.latest!.receivedAt, sample(8).receivedAt);
    await replacement.feed.close();
  });
  test('late open after pause is closed and never displayed', () async {
    final h = Harness();
    addTearDown(h.dispose);
    final pending = Completer<RealtimeFeed>();
    h.api.pending = pending.future;
    final opening = h.controller.start();
    await pump();
    h.controller.pause();
    pending.complete(h.api.feed);
    await opening;
    await pump();
    expect(h.state.phase, LiveMetricsPhase.paused);
    expect(h.api.feed.closed, isTrue);
  });
  test(
    'pause-resume serializes against an unresolved subscribe acknowledgement',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      final pending = Completer<RealtimeFeed>();
      h.api.pending = pending.future;
      final opening = h.controller.start();
      await pump();
      h.controller.pause();
      final restart = h.controller.start();
      await pump();
      expect(h.api.opens, 1);
      final original = h.api.feed;
      h.api.pending = null;
      h.api.feed = FakeFeed();
      pending.complete(original);
      await opening;
      await restart;
      expect(original.closed, isTrue);
      expect(h.api.opens, 2);
    },
  );
  test('disposing while subscribe is pending closes eventual feed', () async {
    final h = Harness();
    final pending = Completer<RealtimeFeed>();
    h.api.pending = pending.future;
    final opening = h.controller.start();
    await pump();
    h.dispose();
    pending.complete(h.api.feed);
    await opening;
    await pump();
    expect(h.api.feed.closed, isTrue);
  });
  test('unsupported capability never opens a source', () async {
    final h = Harness();
    addTearDown(h.dispose);
    h.api.supported = false;
    await h.controller.start();
    expect(h.api.opens, 0);
    expect(h.state.phase, LiveMetricsPhase.unavailable);
  });
  test(
    'duplicate or reversed client receipt times cannot extend a chart',
    () async {
      final h = Harness();
      addTearDown(h.dispose);
      await h.controller.start();
      h.api.feed.emit(sample(5));
      h.api.feed.emit(sample(5));
      h.api.feed.emit(sample(3));
      expect(h.state.samples, hasLength(1));
    },
  );
  test('segments split on nulls and receipt-time gaps', () {
    final points = [
      sample(0),
      sample(2),
      sample(4, usage: null),
      sample(6),
      sample(20),
    ];
    final segments = liveMetricSegments(
      points,
      (s) => s.cpu['cpu']?.usage,
      maximum: 100,
    );
    expect(segments.map((s) => s.length), [2, 1, 1]);
    expect(segments.last.single.dx, 1);
  });
  test('zero-only values use finite scale and valid plotted coordinates', () {
    final segments = liveMetricSegments([
      sample(0, usage: 0),
      sample(2, usage: 0),
    ], (s) => s.cpu['cpu']?.usage);
    expect(segments.single.every((p) => p.dx.isFinite && p.dy == 1), isTrue);
  });
  for (final brightness in Brightness.values) {
    testWidgets('charts fit 320px at 2x text ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.dark
              ? TrueRAIDTheme.dark()
              : TrueRAIDTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TdPanel(
                    title: 'Fixture',
                    child: LiveMetricsCharts(samples: [sample(0), sample(2)]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Physical memory'), findsOneWidget);
      expect(find.text('0.0% — 100%'), findsOneWidget);
      expect(find.text('0 B/s — 1.0 KiB/s'), findsOneWidget);
      expect(
        find.textContaining('Available includes reclaimable'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('mount starts once and unmount closes the feed', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(widget(api));
    await tester.pump();
    expect(api.opens, 1);
    api.feed.emit(sample(0));
    await tester.pump();
    expect(find.text('● Live'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(api.feed.closed, isTrue);
  });
  testWidgets('background pauses and resume reconnects with fresh data', (
    tester,
  ) async {
    final api = FakeApi();
    await tester.pumpWidget(widget(api));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    expect(api.feed.closed, isTrue);
    expect(find.text('Paused'), findsOneWidget);
    api.feed = FakeFeed();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump();
    expect(api.opens, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets('manual pause persists across foreground lifecycle changes', (
    tester,
  ) async {
    final api = FakeApi();
    await tester.pumpWidget(widget(api));
    await tester.pump();
    await tester.tap(find.byKey(const Key('live-metrics-toggle')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(api.opens, 1);
    expect(find.text('Paused'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets('covered route pauses and coming back opens a fresh source', (
    tester,
  ) async {
    final api = FakeApi();
    await tester.pumpWidget(widget(api));
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Other page')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.feed.closed, isTrue);
    api.feed = FakeFeed();
    navigator.pop();
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.opens, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Widget widget(FakeApi api) => ProviderScope(
  overrides: [dashboardActiveSessionProvider.overrideWithValue(session(api))],
  child: MaterialApp(
    theme: TrueRAIDTheme.dark(),
    home: const Scaffold(
      body: SingleChildScrollView(child: DashboardLiveMetrics()),
    ),
  ),
);
RealtimeSample sample(int second, {double? usage = 25}) => RealtimeSample(
  receivedAt: time.add(Duration(seconds: second)),
  cpu: {
    'cpu': RealtimeCpu(usage: usage, temperature: 45),
    'cpu0': const RealtimeCpu(usage: 30),
  },
  interfaces: {
    'eth0': const RealtimeInterface(
      linkUp: true,
      speedMbps: 1000,
      receivedBytesPerSecond: 125000,
      sentBytesPerSecond: 250000,
    ),
  },
  memoryTotalBytes: 1000,
  memoryAvailableBytes: 600,
  arcSizeBytes: 500,
  diskReadBytesPerSecond: 1024,
  diskWriteBytesPerSecond: 2048,
  diskReadOpsPerSecond: 10,
  diskWriteOpsPerSecond: 20,
  diskBusyPercent: 12,
  arcDataHitPercent: 95,
  arcMetadataHitPercent: 99,
);
Future<void> pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

AuthenticatedSession session(FakeApi api) => AuthenticatedSession(
  profileId: 'nas',
  repository: api,
  availableMethodNames: const {},
  version: '25.10.1',
  endpoint: 'wss://nas.example/api/current',
);

class Harness {
  Harness() {
    active = session(api);
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
    listener = container.listen(liveMetricsControllerProvider, (_, _) {});
  }
  final api = FakeApi();
  AuthenticatedSession? active;
  late final ProviderContainer container;
  late final ProviderSubscription<LiveMetricsState> listener;
  LiveMetricsController get controller =>
      container.read(liveMetricsControllerProvider.notifier);
  LiveMetricsState get state => container.read(liveMetricsControllerProvider);
  void dispose() {
    listener.close();
    container.dispose();
  }
}

class FakeFeed implements RealtimeFeed {
  final events = StreamController<RealtimeSample>.broadcast(sync: true);
  bool closed = false;
  void emit(RealtimeSample sample) {
    if (!closed) events.add(sample);
  }

  @override
  Stream<RealtimeSample> get samples => events.stream;
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await Future<void>.value();
    await events.close();
  }
}

class FakeApi implements SessionRepository, AuthenticatedRealtimeSession {
  FakeFeed feed = FakeFeed();
  Future<RealtimeFeed>? pending;
  bool supported = true;
  int opens = 0;
  @override
  RealtimeCapabilities get realtimeCapabilities => RealtimeCapabilities(
    supported: supported,
    blockedReason: supported ? null : 'Fixture unavailable.',
  );
  @override
  Future<RealtimeFeed> openRealtimeFeed() async {
    opens++;
    return pending ?? feed;
  }

  @override
  Future<void> close() => feed.close();
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnimplementedError();
}
