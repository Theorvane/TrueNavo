import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_write_fence.dart';

final iscsiInitiatorCommentCoordinatorProvider =
    Provider<IscsiInitiatorCommentCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiInitiatorCommentCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiCommentOutcome { completed, rejected, unknown }

final class IscsiCommentResult {
  const IscsiCommentResult(this.outcome, this.message);
  final IscsiCommentOutcome outcome;
  final String message;
}

final class IscsiCommentReview {
  IscsiCommentReview._({
    required this.endpoint,
    required this.groupId,
    required this.before,
    required this.proposed,
    required this.proof,
    required this.issuedAt,
  });

  final String endpoint;
  final int groupId;
  final String before, proposed, proof;
  final DateTime issuedAt;
  String get confirmation => 'UPDATE INITIATOR $groupId';
}

final class _CommentSnapshot {
  const _CommentSnapshot(this.id, this.names, this.comment);
  final int id;
  final List<String> names;
  final String comment;
  String get proof => jsonEncode([id, names, comment]);
  String get accessProof => jsonEncode([id, names]);
}

/// Only updates an initiator group's descriptive comment. Access lists are
/// read before and after; no update is replayed when the outcome is unclear.
final class IscsiInitiatorCommentCoordinator {
  IscsiInitiatorCommentCoordinator({
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
  final _issued = <IscsiCommentReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('iscsi.initiator.query')?.supported == true &&
      api.adminCatalog.method('iscsi.initiator.update')?.supported == true;

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI initiator methods are unavailable.');
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

  Future<_CommentSnapshot> _snapshot(int id) async {
    _guard();
    final result = await api.invokeAdmin(
      AdminRequest(
        method: _method('iscsi.initiator.query'),
        arguments: const [],
      ),
    );
    _guard();
    if (result is! AdminCompleted || result.value is! List) {
      throw StateError('The initiator inventory is unavailable.');
    }
    final rows = result.value as List;
    if (rows.length > 100 || rows.any((row) => row is! Map)) {
      throw StateError('The initiator inventory is incomplete.');
    }
    final matches = rows.where((row) => (row as Map)['id'] == id).toList();
    if (matches.length != 1) {
      throw StateError('The selected initiator group is missing or ambiguous.');
    }
    final row = matches.single as Map;
    final names = row['initiators'];
    final comment = row['comment'];
    if (names is! List ||
        names.length > 100 ||
        names.any((name) => name is! String || name.length > 255) ||
        comment is! String ||
        comment.length > 1024) {
      throw StateError('The selected initiator group is incomplete.');
    }
    return _CommentSnapshot(id, List<String>.unmodifiable(names), comment);
  }

  Future<IscsiCommentReview> prepare(int id, String proposed) async {
    _guard();
    if (!available ||
        _busy ||
        id < 1 ||
        proposed.length > 128 ||
        proposed.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError(
        'Choose an existing group and a comment of at most 128 characters.',
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
      final review = IscsiCommentReview._(
        endpoint: session.endpoint!,
        groupId: id,
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
      throw StateError('The initiator preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiCommentReview review) => _issued.remove(review);

  Future<IscsiCommentResult> execute(
    IscsiCommentReview review,
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
      return const IscsiCommentResult(
        IscsiCommentOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiCommentResult(
        IscsiCommentOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot(review.groupId);
      if (before.proof != review.proof) {
        return const IscsiCommentResult(
          IscsiCommentOutcome.rejected,
          'The initiator group changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.initiator.update'),
          arguments: [
            review.groupId,
            {'comment': review.proposed},
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiCommentResult(
          IscsiCommentOutcome.rejected,
          'The server denied this update. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted) return _unknown();
      final after = await _snapshot(review.groupId);
      if (after.accessProof != before.accessProof ||
          after.comment != review.proposed) {
        return _unknown();
      }
      return const IscsiCommentResult(
        IscsiCommentOutcome.completed,
        'The comment matched a fresh inventory read. Client access was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiCommentResult(
              IscsiCommentOutcome.rejected,
              'The initiator preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiCommentResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiCommentResult(
      IscsiCommentOutcome.unknown,
      'The update may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
