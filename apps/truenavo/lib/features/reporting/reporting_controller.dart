import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';

final reportingSessionProvider = Provider<AuthenticatedReportingSession?>((
  ref,
) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return switch (repository) {
    final AuthenticatedReportingSession reporting => reporting,
    _ => null,
  };
});

final reportingGraphsProvider = FutureProvider<List<ReportingGraph>>((
  ref,
) async {
  final session = ref.watch(reportingSessionProvider);
  if (session == null) return const [];
  return session.loadReportingGraphs();
});

final reportingClockProvider = Provider<DateTime Function()>((ref) {
  return () => DateTime.now().toUtc();
});

enum ReportingRange {
  hour('Last hour', Duration(hours: 1)),
  day('Last 24 hours', Duration(days: 1)),
  week('Last 7 days', Duration(days: 7)),
  month('Last 30 days', Duration(days: 30)),
  year('Last 365 days', Duration(days: 365));

  const ReportingRange(this.label, this.duration);
  final String label;
  final Duration duration;
}

enum ReportingPhase { idle, loading, ready, empty, failed }

/// An explicit UTC interval. Null in state means a rolling preset instead.
final class ReportingWindow {
  ReportingWindow({required DateTime start, required DateTime end})
    : start = start.toUtc(),
      end = end.toUtc();
  final DateTime start;
  final DateTime end;
  Duration get duration => end.difference(start);
  bool get valid =>
      start.millisecondsSinceEpoch > 0 &&
      end.year <= 9999 &&
      duration >= const Duration(minutes: 1) &&
      duration <= const Duration(days: 365);
}

final class ReportingState {
  ReportingState({
    this.phase = ReportingPhase.idle,
    this.graph,
    this.identifier,
    this.range = ReportingRange.hour,
    List<ReportingHistory> histories = const [],
    this.serverLabel,
    this.message,
    this.loadedAt,
    this.window,
    this.requestedWindow,
  }) : histories = List.unmodifiable(histories);

  final ReportingPhase phase;
  final ReportingGraph? graph;
  final String? identifier;
  final ReportingRange range;
  final List<ReportingHistory> histories;
  final String? serverLabel;
  final String? message;
  final DateTime? loadedAt;
  final ReportingWindow? window;
  final ReportingWindow? requestedWindow;
  bool get busy => phase == ReportingPhase.loading;
}

final reportingControllerProvider =
    NotifierProvider<ReportingController, ReportingState>(
      ReportingController.new,
    );

class ReportingController extends Notifier<ReportingState> {
  AuthenticatedSession? _operationSession;
  AuthenticatedSession? get operationSession => _operationSession;
  int _generation = 0;
  bool _draining = false;
  _ReportingLoad? _pending;

  @override
  ReportingState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (identical(next, _operationSession)) return;
      _generation++;
      _operationSession = null;
      _cancelQueued();
      state = ReportingState();
    });
    ref.onDispose(() {
      _generation++;
      _cancelQueued();
    });
    return ReportingState();
  }

  /// Drop a previous local graph before opening an explicitly requested metric.
  /// An in-flight read may finish, but its generation can no longer publish.
  void clearSelection() {
    _generation++;
    _cancelQueued();
    _operationSession = null;
    state = ReportingState();
  }

  Future<void> load({
    required AuthenticatedSession expectedSession,
    required ReportingGraph graph,
    String? identifier,
    ReportingRange range = ReportingRange.hour,
    ReportingWindow? window,
  }) async {
    if (!identical(ref.read(dashboardActiveSessionProvider), expectedSession)) {
      return;
    }
    if (expectedSession.repository is! AuthenticatedReportingSession) return;
    if (window != null &&
        (!window.valid ||
            window.end.isAfter(ref.read(reportingClockProvider)().toUtc()))) {
      return;
    }
    final pending = _ReportingLoad(
      expectedSession,
      graph,
      identifier,
      range,
      window,
    );
    _cancelQueued();
    _pending = pending;
    _generation++; // A newer selection must hide the active request's result.
    _operationSession = expectedSession;
    state = ReportingState(
      phase: ReportingPhase.loading,
      graph: graph,
      identifier: identifier,
      range: range,
      window: window,
      serverLabel: expectedSession.endpoint,
      message: _draining
          ? 'Waiting for the current read, then loading your latest selection…'
          : 'Loading measurements reported by this server…',
    );
    if (!_draining) unawaited(_drain());
    await pending.done.future;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (ref.mounted && _pending != null) {
        final pending = _pending!;
        _pending = null;
        try {
          await _loadNow(
            expectedSession: pending.session,
            graph: pending.graph,
            identifier: pending.identifier,
            range: pending.range,
            window: pending.window,
          );
        } finally {
          if (!pending.done.isCompleted) pending.done.complete();
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _cancelQueued() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.done.isCompleted) pending.done.complete();
  }

  Future<void> _loadNow({
    required AuthenticatedSession expectedSession,
    required ReportingGraph graph,
    required String? identifier,
    required ReportingRange range,
    required ReportingWindow? window,
  }) async {
    if (!identical(ref.read(dashboardActiveSessionProvider), expectedSession)) {
      return;
    }
    final repository = expectedSession.repository;
    if (repository is! AuthenticatedReportingSession) return;
    final generation = ++_generation;
    _operationSession = expectedSession;
    final end = window?.end ?? ref.read(reportingClockProvider)().toUtc();
    final requestedWindow =
        window ??
        ReportingWindow(start: end.subtract(range.duration), end: end);
    final request = ReportingRequest(
      graph: graph,
      identifier: identifier,
      start: requestedWindow.start,
      end: end,
    );
    state = ReportingState(
      phase: ReportingPhase.loading,
      graph: graph,
      identifier: identifier,
      range: range,
      window: window,
      requestedWindow: requestedWindow,
      serverLabel: expectedSession.endpoint,
      message: 'Loading measurements reported by this server…',
    );
    try {
      final histories = await (repository as AuthenticatedReportingSession)
          .loadReportingHistory(request);
      if (!_current(generation, expectedSession)) return;
      final hasValues = histories.any(
        (history) => history.points.any(
          (point) => point.values.any((value) => value != null),
        ),
      );
      state = ReportingState(
        phase: hasValues ? ReportingPhase.ready : ReportingPhase.empty,
        graph: graph,
        identifier: identifier,
        range: range,
        window: window,
        requestedWindow: requestedWindow,
        histories: histories,
        serverLabel: expectedSession.endpoint,
        loadedAt: ref.read(reportingClockProvider)().toUtc(),
        message: hasValues
            ? null
            : 'No usable measurements were returned for this selection. '
                  'Unavailable history is not displayed as zero.',
      );
    } on ReportingException catch (error) {
      if (!_current(generation, expectedSession)) return;
      state = ReportingState(
        phase: ReportingPhase.failed,
        graph: graph,
        identifier: identifier,
        range: range,
        window: window,
        requestedWindow: requestedWindow,
        serverLabel: expectedSession.endpoint,
        message: error.userMessage,
      );
    } catch (_) {
      if (!_current(generation, expectedSession)) return;
      state = ReportingState(
        phase: ReportingPhase.failed,
        graph: graph,
        identifier: identifier,
        range: range,
        window: window,
        requestedWindow: requestedWindow,
        serverLabel: expectedSession.endpoint,
        message:
            'This reporting history could not be loaded safely. '
            'The server may not support this graph or the selected range.',
      );
    }
  }

  Future<void> refresh() async {
    final session = _operationSession;
    final graph = state.graph;
    if (session == null ||
        graph == null ||
        state.busy ||
        !identical(ref.read(dashboardActiveSessionProvider), session)) {
      return;
    }
    await load(
      expectedSession: session,
      graph: graph,
      identifier: state.identifier,
      range: state.range,
      window: state.window,
    );
  }

  Future<void> movePeriod({required bool forward}) async {
    final session = _operationSession;
    final graph = state.graph;
    final current = state.requestedWindow;
    if (session == null || graph == null || current == null || state.busy) {
      return;
    }
    final now = ref.read(reportingClockProvider)().toUtc();
    if (forward && !current.end.isBefore(now)) return;
    var end = forward ? current.end.add(current.duration) : current.start;
    if (end.isAfter(now)) end = now;
    await load(
      expectedSession: session,
      graph: graph,
      identifier: state.identifier,
      range: state.range,
      window: ReportingWindow(start: end.subtract(current.duration), end: end),
    );
  }

  Future<void> returnToLatest() async {
    final session = _operationSession;
    final graph = state.graph;
    if (session == null || graph == null || state.busy) return;
    await load(
      expectedSession: session,
      graph: graph,
      identifier: state.identifier,
      range: state.range,
    );
  }

  bool _current(int generation, AuthenticatedSession expected) =>
      ref.mounted &&
      generation == _generation &&
      identical(ref.read(dashboardActiveSessionProvider), expected);
}

final class _ReportingLoad {
  _ReportingLoad(
    this.session,
    this.graph,
    this.identifier,
    this.range,
    this.window,
  );
  final AuthenticatedSession session;
  final ReportingGraph graph;
  final String? identifier;
  final ReportingRange range;
  final ReportingWindow? window;
  final done = Completer<void>();
}
