import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiThresholdCoordinatorProvider = Provider<IscsiThresholdCoordinator?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  if (session?.endpoint == null ||
      session!.repository is! AuthenticatedAdminSession) {
    return null;
  }
  return IscsiThresholdCoordinator(
    session: session,
    api: session.repository as AuthenticatedAdminSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

enum IscsiThresholdOutcome { completed, rejected, unknown }

final class IscsiThresholdResult {
  const IscsiThresholdResult(this.outcome, this.message);
  final IscsiThresholdOutcome outcome;
  final String message;
}

final class IscsiThresholdReview {
  IscsiThresholdReview._({
    required this.endpoint,
    required this.before,
    required this.proposed,
    required this.proof,
    required this.issuedAt,
  });

  final String endpoint;
  final int? before, proposed;
  final String proof;
  final DateTime issuedAt;
  String get confirmation => 'UPDATE ISCSI $endpoint';
}

final class _ThresholdSnapshot {
  const _ThresholdSnapshot(
    this.configId,
    this.config,
    this.service,
    this.noSessions,
  );
  final int configId;
  final IscsiGlobalConfig config;
  final IscsiServiceStatus service;
  final bool noSessions;

  String get proof => jsonEncode([
    configId,
    config.basename,
    config.isnsServers,
    config.listenPort,
    config.poolAvailThreshold,
    config.alua,
    config.iser,
    service.state,
    service.enabledOnBoot,
    noSessions,
  ]);

  String get unchangedFields => jsonEncode([
    configId,
    config.basename,
    config.isnsServers,
    config.listenPort,
    config.alua,
    config.iser,
    service.enabledOnBoot,
  ]);
}

/// One narrow, reviewed global edit. It never starts or stops iSCSI and never
/// retries a submitted update. The server has no atomic config compare-and-swap.
final class IscsiThresholdCoordinator {
  IscsiThresholdCoordinator({
    required this.session,
    required this.api,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <IscsiThresholdReview>{};
  bool _busy = false;
  bool get _terminalUnknown => IscsiWriteFence.isUncertain(session);

  bool get locked => _terminalUnknown || _busy;
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.global.config',
        'iscsi.global.sessions',
        'service.query',
        'iscsi.global.update',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  AdminMethodSpec _method(String name) {
    final spec = api.adminCatalog.method(name);
    if (!available || spec == null || !spec.supported) {
      throw StateError('Required iSCSI methods are unavailable.');
    }
    return spec;
  }

  void _guard() {
    if (!isCurrent() || session.endpoint == null) {
      throw StateError('The server connection changed.');
    }
    if (_terminalUnknown) {
      throw StateError(
        'A previous iSCSI update is unverified. Reconnect before another change.',
      );
    }
  }

  Future<AdminCompleted> _read(String name, List<Object?> arguments) async {
    _guard();
    final result = await api.invokeAdmin(
      AdminRequest(method: _method(name), arguments: arguments),
    );
    _guard();
    if (result is! AdminCompleted) {
      throw StateError('The iSCSI preflight could not be verified.');
    }
    return result;
  }

  Future<_ThresholdSnapshot> _snapshot() async {
    final rawConfig = (await _read('iscsi.global.config', const [])).value;
    if (rawConfig is! Map ||
        rawConfig['id'] is! int ||
        !rawConfig.containsKey('pool_avail_threshold')) {
      throw StateError(
        'The iSCSI configuration identity or threshold is incomplete.',
      );
    }
    final config = IscsiGlobalConfig.parse(rawConfig);
    final serviceRaw = (await _read('service.query', const [
      [
        ['service', '=', 'iscsitarget'],
      ],
      {'limit': 2},
    ])).value;
    final service = IscsiServiceStatus.parse(serviceRaw);
    if (service == null) {
      throw StateError('The iSCSI service state is unavailable.');
    }
    final sessions = (await _read('iscsi.global.sessions', const [])).value;
    if (sessions is! List || sessions.length > 100) {
      throw StateError('The active-session report is incomplete.');
    }
    return _ThresholdSnapshot(
      rawConfig['id'] as int,
      config,
      service,
      sessions.isEmpty,
    );
  }

  Future<IscsiThresholdReview> prepare(int? proposed) async {
    _guard();
    if (!available ||
        _busy ||
        (proposed != null && (proposed < 1 || proposed > 99))) {
      throw StateError('Choose Off or a threshold from 1 to 99%.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final current = await _snapshot();
      if (current.service.state != 'STOPPED' || !current.noSessions) {
        throw StateError(
          'Stop iSCSI and disconnect all clients independently before editing.',
        );
      }
      if (current.config.poolAvailThreshold == proposed) {
        throw StateError('The requested threshold is already configured.');
      }
      final review = IscsiThresholdReview._(
        endpoint: session.endpoint!,
        before: current.config.poolAvailThreshold,
        proposed: proposed,
        proof: current.proof,
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'The iSCSI preflight could not be verified. No update was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiThresholdReview review) => _issued.remove(review);

  Future<IscsiThresholdResult> execute(
    IscsiThresholdReview review,
    String confirmation,
  ) async {
    final issued = _issued.remove(review);
    if (!issued ||
        _busy ||
        _terminalUnknown ||
        !isCurrent() ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        _now().toUtc().isBefore(review.issuedAt) ||
        _now().toUtc().difference(review.issuedAt) >=
            const Duration(minutes: 5)) {
      return const IscsiThresholdResult(
        IscsiThresholdOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiThresholdResult(
        IscsiThresholdOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      if (before.proof != review.proof ||
          before.service.state != 'STOPPED' ||
          !before.noSessions ||
          !isCurrent()) {
        throw StateError('iSCSI state changed since review. Nothing was sent.');
      }
      final request = AdminRequest(
        method: _method('iscsi.global.update'),
        arguments: [
          {'pool_avail_threshold': review.proposed},
        ],
      );
      sent = true;
      final result = await api.invokeAdmin(request);
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiThresholdResult(
          IscsiThresholdOutcome.rejected,
          'The server denied this update. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted) return _unknown();
      final after = await _snapshot();
      if (after.config.poolAvailThreshold != review.proposed ||
          after.unchangedFields != before.unchangedFields ||
          after.service.state != 'STOPPED' ||
          !after.noSessions) {
        return _unknown();
      }
      return const IscsiThresholdResult(
        IscsiThresholdOutcome.completed,
        'The threshold matched a fresh configuration read. Client access was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiThresholdResult(
              IscsiThresholdOutcome.rejected,
              'iSCSI preflight changed or failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiThresholdResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiThresholdResult(
      IscsiThresholdOutcome.unknown,
      'The update may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
