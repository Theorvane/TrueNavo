import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import 'dashboard_controller.dart';

enum LiveMetricsPhase { idle, connecting, live, paused, unavailable }

final class LiveMetricsState {
  LiveMetricsState({
    this.phase = LiveMetricsPhase.idle,
    List<RealtimeSample> samples = const [],
    this.endpoint,
    this.message,
  }) : samples = List.unmodifiable(samples);
  final LiveMetricsPhase phase;
  final List<RealtimeSample> samples;
  final String? endpoint;
  final String? message;
  RealtimeSample? get latest => samples.lastOrNull;
}

final liveMetricsControllerProvider =
    NotifierProvider.autoDispose<LiveMetricsController, LiveMetricsState>(
      LiveMetricsController.new,
    );

class LiveMetricsController extends Notifier<LiveMetricsState> {
  AuthenticatedSession? _session;
  RealtimeFeed? _feed;
  Future<RealtimeFeed>? _pendingOpen;
  StreamSubscription<RealtimeSample>? _subscription;
  int _generation = 0;
  bool _enabled = false;
  Future<void> _closing = Future.value();

  @override
  LiveMetricsState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (identical(_session, next)) return;
      _generation++;
      _session = null;
      _stop();
      state = LiveMetricsState();
      if (_enabled) unawaited(start());
    });
    ref.onDispose(() {
      _generation++;
      _enabled = false;
      _stop();
    });
    return LiveMetricsState();
  }

  Future<void> start() async {
    _enabled = true;
    if (state.phase == LiveMetricsPhase.connecting ||
        state.phase == LiveMetricsPhase.live) {
      return;
    }
    final session = ref.read(dashboardActiveSessionProvider);
    final repository = session?.repository;
    if (session == null || repository is! AuthenticatedRealtimeSession) {
      state = LiveMetricsState(
        phase: LiveMetricsPhase.unavailable,
        message: 'Live reporting is not available for this connection.',
      );
      return;
    }
    final realtime = repository as AuthenticatedRealtimeSession;
    final capability = realtime.realtimeCapabilities;
    if (!capability.supported) {
      state = LiveMetricsState(
        phase: LiveMetricsPhase.unavailable,
        endpoint: session.endpoint,
        message: capability.blockedReason,
      );
      return;
    }
    final generation = ++_generation;
    _session = session;
    state = LiveMetricsState(
      phase: LiveMetricsPhase.connecting,
      endpoint: session.endpoint,
    );
    await _closing;
    if (!_current(generation, session)) return;
    try {
      final pending = realtime.openRealtimeFeed();
      _pendingOpen = pending;
      final feed = await pending;
      if (identical(_pendingOpen, pending)) _pendingOpen = null;
      if (!_current(generation, session)) {
        await feed.close();
        return;
      }
      _feed = feed;
      _subscription = feed.samples.listen(
        (sample) {
          if (!_current(generation, session)) return;
          final previous = state.samples;
          if (previous.isNotEmpty &&
              !sample.receivedAt.isAfter(previous.last.receivedAt)) {
            return;
          }
          final next = [...previous, sample];
          state = LiveMetricsState(
            phase: LiveMetricsPhase.live,
            endpoint: session.endpoint,
            samples: next.length > 60 ? next.sublist(next.length - 60) : next,
          );
        },
        onError: (Object _) => _failed(generation, session),
        onDone: () => _failed(generation, session),
      );
    } on Object {
      _failed(generation, session);
    }
  }

  bool _current(int generation, AuthenticatedSession session) =>
      ref.mounted &&
      _enabled &&
      generation == _generation &&
      identical(ref.read(dashboardActiveSessionProvider), session);

  void _failed(int generation, AuthenticatedSession session) {
    if (!_current(generation, session)) return;
    _generation++;
    _stop();
    // Do not leave stale values wearing a live badge or automatically retry.
    state = LiveMetricsState(
      phase: LiveMetricsPhase.unavailable,
      endpoint: session.endpoint,
      message: const RealtimeException().userMessage,
    );
  }

  void pause() {
    _enabled = false;
    _generation++;
    _stop();
    state = LiveMetricsState(
      phase: LiveMetricsPhase.paused,
      endpoint: state.endpoint,
      message: 'Live reporting paused. Resume to receive new measurements.',
    );
  }

  void _stop() {
    final subscription = _subscription;
    final feed = _feed;
    final pending = _pendingOpen;
    _subscription = null;
    _feed = null;
    _pendingOpen = null;
    // Stop production at once; a slow consumer cancellation must not postpone
    // cancelling the server event source (especially while backgrounded).
    final cancellation = _quiet(() => subscription?.cancel());
    final closure = _quiet(() => feed?.close());
    _closing = _closing.then((_) async {
      try {
        await cancellation;
        await closure;
        await (await pending)?.close();
      } on Object {
        /* Already disconnected or unsubscribed. */
      }
    });
  }
}

Future<void> _quiet(Future<void>? Function() close) async {
  try {
    await close();
  } on Object {
    /* Teardown errors contain no user data. */
  }
}
