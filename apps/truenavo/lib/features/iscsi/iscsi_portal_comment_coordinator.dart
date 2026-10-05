import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_write_fence.dart';

final iscsiPortalCommentCoordinatorProvider =
    Provider<IscsiPortalCommentCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiPortalCommentCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiPortalCommentOutcome { completed, rejected, unknown }

final class IscsiPortalCommentResult {
  const IscsiPortalCommentResult(this.outcome, this.message);
  final IscsiPortalCommentOutcome outcome;
  final String message;
}

final class IscsiPortalCommentReview {
  IscsiPortalCommentReview._({
    required this.endpoint,
    required this.portalId,
    required this.before,
    required this.proposed,
    required this.proof,
    required this.issuedAt,
  });

  final String endpoint;
  final int portalId;
  final String before, proposed, proof;
  final DateTime issuedAt;
  String get confirmation => 'UPDATE PORTAL $portalId';
}

final class _PortalSnapshot {
  const _PortalSnapshot(this.id, this.tag, this.listeners, this.comment);
  final int id, tag;
  final List<List<Object>> listeners;
  final String comment;
  String get proof => jsonEncode([id, tag, listeners, comment]);
  String get listenerProof => jsonEncode([id, tag, listeners]);
}

/// A single comment-only write with fresh topology preflight and readback.
/// It cannot establish client reachability or exclude concurrent admins.
final class IscsiPortalCommentCoordinator {
  IscsiPortalCommentCoordinator({
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
  final _issued = <IscsiPortalCommentReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('iscsi.portal.query')?.supported == true &&
      api.adminCatalog.method('iscsi.portal.update')?.supported == true;

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI portal methods are unavailable.');
    }
    return method;
  }

  void _guard() {
    if (!isCurrent() || session.endpoint == null) {
      throw StateError('The server connection changed.');
    }
    if (IscsiWriteFence.isUncertain(session)) {
      throw StateError(
        'An iSCSI update is unverified. Reconnect before editing.',
      );
    }
  }

  Future<_PortalSnapshot> _snapshot(int id) async {
    _guard();
    final result = await api.invokeAdmin(
      AdminRequest(method: _method('iscsi.portal.query'), arguments: const []),
    );
    _guard();
    if (result is! AdminCompleted || result.value is! List) {
      throw StateError('The portal inventory is unavailable.');
    }
    final rows = result.value as List;
    if (rows.length > 100 || rows.any((row) => row is! Map)) {
      throw StateError('The portal inventory is incomplete.');
    }
    final matches = rows.where((row) => (row as Map)['id'] == id).toList();
    if (matches.length != 1) {
      throw StateError('The selected portal is missing or ambiguous.');
    }
    final row = matches.single as Map;
    final tag = row['tag'];
    final comment = row['comment'];
    final listen = row['listen'];
    if (tag is! int ||
        tag < 1 ||
        comment is! String ||
        comment.length > 1024 ||
        listen is! List ||
        listen.length > 100) {
      throw StateError('The selected portal is incomplete.');
    }
    final listeners = <List<Object>>[];
    for (final item in listen) {
      if (item is! Map ||
          item['ip'] is! String ||
          (item['ip'] as String).isEmpty ||
          (item['ip'] as String).length > 255 ||
          item['port'] is! int ||
          (item['port'] as int) < 1 ||
          (item['port'] as int) > 65535) {
        throw StateError('The selected portal listeners are incomplete.');
      }
      listeners.add([item['ip'] as String, item['port'] as int]);
    }
    return _PortalSnapshot(id, tag, List.unmodifiable(listeners), comment);
  }

  Future<IscsiPortalCommentReview> prepare(int id, String proposed) async {
    _guard();
    if (!available ||
        _busy ||
        id < 1 ||
        proposed.length > 128 ||
        proposed.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError(
        'Choose an existing portal and a comment of at most 128 characters.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final before = await _snapshot(id);
      if (before.comment == proposed) {
        throw StateError('The requested comment is already configured.');
      }
      final review = IscsiPortalCommentReview._(
        endpoint: session.endpoint!,
        portalId: id,
        before: before.comment,
        proposed: proposed,
        proof: before.proof,
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The portal preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiPortalCommentReview review) => _issued.remove(review);

  Future<IscsiPortalCommentResult> execute(
    IscsiPortalCommentReview review,
    String confirmation,
  ) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        _busy ||
        !isCurrent() ||
        IscsiWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const IscsiPortalCommentResult(
        IscsiPortalCommentOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiPortalCommentResult(
        IscsiPortalCommentOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot(review.portalId);
      if (before.proof != review.proof) {
        return const IscsiPortalCommentResult(
          IscsiPortalCommentOutcome.rejected,
          'The portal changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.portal.update'),
          arguments: [
            review.portalId,
            {'comment': review.proposed},
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiPortalCommentResult(
          IscsiPortalCommentOutcome.rejected,
          'The server denied this update. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted) return _unknown();
      final after = await _snapshot(review.portalId);
      if (after.listenerProof != before.listenerProof ||
          after.comment != review.proposed) {
        return _unknown();
      }
      return const IscsiPortalCommentResult(
        IscsiPortalCommentOutcome.completed,
        'The comment matched a fresh inventory read. Client reachability was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiPortalCommentResult(
              IscsiPortalCommentOutcome.rejected,
              'The portal preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiPortalCommentResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiPortalCommentResult(
      IscsiPortalCommentOutcome.unknown,
      'The update may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
