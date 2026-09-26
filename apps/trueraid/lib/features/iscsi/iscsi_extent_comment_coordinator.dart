import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_write_fence.dart';

final iscsiExtentCommentCoordinatorProvider =
    Provider<IscsiExtentCommentCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiExtentCommentCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiExtentCommentOutcome { completed, rejected, unknown }

final class IscsiExtentCommentResult {
  const IscsiExtentCommentResult(this.outcome, this.message);
  final IscsiExtentCommentOutcome outcome;
  final String message;
}

final class IscsiExtentCommentReview {
  IscsiExtentCommentReview._(
    this._proof, {
    required this.endpoint,
    required this.extentId,
    required this.name,
    required this.before,
    required this.proposed,
    required this.issuedAt,
  });

  final String endpoint;
  final int extentId;
  final String name, before, proposed;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation => 'UPDATE EXTENT $extentId';
}

final class _ExtentSnapshot {
  const _ExtentSnapshot(this.id, this.name, this.comment, this.proof);
  final int id;
  final String name, comment, proof;
}

/// A comment-only edit. The full bounded row is compared before submission;
/// readback confirms the intended comment and unchanged non-comment fields.
final class IscsiExtentCommentCoordinator {
  IscsiExtentCommentCoordinator({
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
  final _issued = <IscsiExtentCommentReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('iscsi.extent.get_instance')?.supported == true &&
      api.adminCatalog.method('iscsi.extent.update')?.supported == true;

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI extent methods are unavailable.');
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

  Future<_ExtentSnapshot> _snapshot(int id) async {
    _guard();
    final result = await api.invokeAdmin(
      AdminRequest(
        method: _method('iscsi.extent.get_instance'),
        arguments: [id],
      ),
    );
    _guard();
    if (result is! AdminCompleted || result.value is! Map) {
      throw StateError('The selected extent is unavailable.');
    }
    final raw = result.value as Map;
    if (raw.length >= 100 || raw['id'] != id) {
      throw StateError('The selected extent identity is incomplete.');
    }
    final name = raw['name'];
    final type = raw['type'];
    final comment = raw['comment'];
    if (name is! String ||
        name.isEmpty ||
        name.length > 64 ||
        (type != 'DISK' && type != 'FILE') ||
        comment is! String ||
        comment.length > 1024 ||
        raw['enabled'] is! bool ||
        raw['ro'] is! bool) {
      throw StateError('The selected extent configuration is incomplete.');
    }
    final stable = Map<Object?, Object?>.from(raw)..remove('comment');
    final canonical = jsonEncode(_canonical(stable));
    if (canonical.length > 32768) {
      throw StateError('The selected extent configuration is too large.');
    }
    final proof = sha256.convert(utf8.encode(canonical)).toString();
    return _ExtentSnapshot(id, name, comment, proof);
  }

  Future<IscsiExtentCommentReview> prepare(int id, String proposed) async {
    _guard();
    if (!available ||
        _busy ||
        id < 1 ||
        proposed.length > 128 ||
        proposed.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError(
        'Choose an existing extent and a comment of at most 128 characters.',
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
      final review = IscsiExtentCommentReview._(
        before.proof,
        endpoint: session.endpoint!,
        extentId: id,
        name: before.name,
        before: before.comment,
        proposed: proposed,
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The extent preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiExtentCommentReview review) => _issued.remove(review);

  Future<IscsiExtentCommentResult> execute(
    IscsiExtentCommentReview review,
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
      return const IscsiExtentCommentResult(
        IscsiExtentCommentOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiExtentCommentResult(
        IscsiExtentCommentOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot(review.extentId);
      if (before.proof != review._proof || before.comment != review.before) {
        return const IscsiExtentCommentResult(
          IscsiExtentCommentOutcome.rejected,
          'The extent changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.extent.update'),
          arguments: [
            review.extentId,
            {'comment': review.proposed},
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiExtentCommentResult(
          IscsiExtentCommentOutcome.rejected,
          'The server denied this update. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted) return _unknown();
      final after = await _snapshot(review.extentId);
      if (after.proof != before.proof || after.comment != review.proposed) {
        return _unknown();
      }
      return const IscsiExtentCommentResult(
        IscsiExtentCommentOutcome.completed,
        'The comment matched a fresh extent read. Client I/O was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiExtentCommentResult(
              IscsiExtentCommentOutcome.rejected,
              'The extent preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiExtentCommentResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiExtentCommentResult(
      IscsiExtentCommentOutcome.unknown,
      'The update may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}

Object? _canonical(Object? value, [int depth = 0]) {
  if (depth > 6) throw const FormatException('Nested extent data is too deep.');
  if (value == null || value is bool || value is num) return value;
  if (value is String) {
    if (value.length > 512 || value == '[truncated]' || value == '[redacted]') {
      throw const FormatException('Incomplete extent data.');
    }
    return value;
  }
  if (value is List) {
    if (value.length >= 100) {
      throw const FormatException('Incomplete extent list.');
    }
    return [for (final item in value) _canonical(item, depth + 1)];
  }
  if (value is Map) {
    if (value.length >= 100 || value.keys.any((key) => key is! String)) {
      throw const FormatException('Incomplete extent fields.');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key], depth + 1)};
  }
  throw const FormatException('Unsupported extent data.');
}
