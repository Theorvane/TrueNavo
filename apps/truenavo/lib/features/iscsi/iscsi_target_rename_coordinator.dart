import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiTargetRenameCoordinatorProvider =
    Provider<IscsiTargetRenameCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiTargetRenameCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiTargetRenameOutcome { completed, rejected, unknown }

final class IscsiTargetRenameResult {
  const IscsiTargetRenameResult(this.outcome, this.message);
  final IscsiTargetRenameOutcome outcome;
  final String message;
}

final class IscsiTargetRenameReview {
  IscsiTargetRenameReview._({
    required this.endpoint,
    required this.id,
    required this.oldName,
    required this.newName,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, oldName, newName, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation => 'RENAME ISCSI TARGET #$id $oldName TO $newName';
}

final class _Snapshot {
  const _Snapshot(this.name, this.proof, this.stableProof);
  final String name, proof, stableProof;
}

/// Renames only an unbound, unmapped target while iSCSI is stopped. Reads are
/// sequential; another administrator can still race this workflow.
final class IscsiTargetRenameCoordinator {
  IscsiTargetRenameCoordinator({
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
  final _issued = <IscsiTargetRenameReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.target.get_instance',
        'iscsi.targetextent.query',
        'iscsi.target.validate_name',
        'iscsi.target.update',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI target methods are unavailable.');
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

  Future<Object?> _read(String name, List<Object?> args) async {
    _guard();
    final result = await api.invokeAdmin(
      AdminRequest(method: _method(name), arguments: args),
    );
    _guard();
    if (result is! AdminCompleted) {
      throw StateError('The iSCSI preflight is unavailable.');
    }
    return result.value;
  }

  Future<_Snapshot> _snapshot(int id) async {
    final raw = await _read('iscsi.target.get_instance', [id]);
    if (raw is! Map ||
        raw['id'] != id ||
        raw.length >= 100 ||
        raw['name'] is! String ||
        (raw['name'] as String).isEmpty ||
        (raw['name'] as String).length > 120 ||
        raw['mode'] != 'ISCSI' ||
        raw['groups'] is! List ||
        (raw['groups'] as List).isNotEmpty ||
        raw['auth_networks'] is! List ||
        (raw['auth_networks'] as List).isNotEmpty) {
      throw StateError(
        'Only a complete, unbound iSCSI target can be renamed here.',
      );
    }
    final mappings = await _read('iscsi.targetextent.query', const []);
    if (mappings is! List ||
        mappings.length >= 100 ||
        mappings.any((item) => item is! Map)) {
      throw StateError('The LUN inventory is incomplete.');
    }
    final mappingIds = <int>{};
    final normalizedMappings = <Map>[];
    for (final item in mappings) {
      final mapping = item as Map;
      final mappingId = mapping['id'];
      final target = mapping['target'];
      final extent = mapping['extent'];
      final lun = mapping['lunid'];
      if (mappingId is! int ||
          mappingId < 1 ||
          !mappingIds.add(mappingId) ||
          target is! int ||
          target < 1 ||
          extent is! int ||
          extent < 1 ||
          lun is! int ||
          lun < 0) {
        throw StateError('The LUN inventory is incomplete.');
      }
      if (target == id) {
        throw StateError(
          'Remove target LUN mappings independently before renaming.',
        );
      }
      normalizedMappings.add(mapping);
    }
    normalizedMappings.sort(
      (a, b) => (a['id'] as int).compareTo(b['id'] as int),
    );
    final service = IscsiServiceStatus.parse(
      await _read('service.query', const [
        [
          ['service', '=', 'iscsitarget'],
        ],
        {'limit': 2},
      ]),
    );
    final sessions = await _read('iscsi.global.sessions', const []);
    if (service == null ||
        service.state != 'STOPPED' ||
        sessions is! List ||
        sessions.length > 100 ||
        sessions.isNotEmpty) {
      throw StateError(
        'Stop iSCSI and disconnect all clients before renaming.',
      );
    }
    final stable = Map<Object?, Object?>.from(raw)..remove('name');
    final context = [normalizedMappings, service.state, service.enabledOnBoot];
    final proof = _digest([raw, context]);
    final stableProof = _digest([stable, context]);
    return _Snapshot(raw['name'] as String, proof, stableProof);
  }

  Future<void> _validateName(String name, int id) async {
    final value = await _read('iscsi.target.validate_name', [name, id]);
    if (value != null) {
      throw StateError('The server did not accept this target name.');
    }
  }

  Future<IscsiTargetRenameReview> prepare(int id, String newName) async {
    _guard();
    if (!available ||
        _busy ||
        id < 1 ||
        newName.isEmpty ||
        newName.length > 120 ||
        newName.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError(
        'Choose a target and enter a name of 1–120 characters without control characters.',
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
      if (before.name == newName) {
        throw StateError('This name is already configured.');
      }
      await _validateName(newName, id);
      final review = IscsiTargetRenameReview._(
        endpoint: session.endpoint!,
        id: id,
        oldName: before.name,
        newName: newName,
        proof: before.proof,
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The target preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiTargetRenameReview review) => _issued.remove(review);

  Future<IscsiTargetRenameResult> execute(
    IscsiTargetRenameReview review,
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
      return const IscsiTargetRenameResult(
        IscsiTargetRenameOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiTargetRenameResult(
        IscsiTargetRenameOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot(review.id);
      if (before.proof != review.proof || before.name != review.oldName) {
        return const IscsiTargetRenameResult(
          IscsiTargetRenameOutcome.rejected,
          'Target, LUN or service state changed since review. Nothing was sent.',
        );
      }
      await _validateName(review.newName, review.id);
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.target.update'),
          arguments: [
            review.id,
            {'name': review.newName},
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiTargetRenameResult(
          IscsiTargetRenameOutcome.rejected,
          'The server denied this update. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted ||
          result.value is! Map ||
          (result.value as Map)['id'] != review.id ||
          (result.value as Map)['name'] != review.newName) {
        return _unknown();
      }
      final after = await _snapshot(review.id);
      if (after.name != review.newName ||
          after.stableProof != before.stableProof) {
        return _unknown();
      }
      return const IscsiTargetRenameResult(
        IscsiTargetRenameOutcome.completed,
        'The new name matched a fresh target read. Client discovery and access were not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiTargetRenameResult(
              IscsiTargetRenameOutcome.rejected,
              'The target preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiTargetRenameResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiTargetRenameResult(
      IscsiTargetRenameOutcome.unknown,
      'The rename may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}

String _digest(Object? value) {
  final canonical = jsonEncode(_canonical(value));
  if (canonical.length > 32768) {
    throw const FormatException('Target data is too large.');
  }
  return sha256.convert(utf8.encode(canonical)).toString();
}

Object? _canonical(Object? value, [int depth = 0]) {
  if (depth > 6) throw const FormatException('Target data is too deep.');
  if (value == null || value is bool || value is num) return value;
  if (value is String) {
    if (value.length > 512 || value == '[truncated]' || value == '[redacted]') {
      throw const FormatException('Incomplete target data.');
    }
    return value;
  }
  if (value is List) {
    if (value.length >= 100) {
      throw const FormatException('Incomplete target list.');
    }
    return [for (final item in value) _canonical(item, depth + 1)];
  }
  if (value is Map) {
    if (value.length >= 100 || value.keys.any((key) => key is! String)) {
      throw const FormatException('Incomplete target fields.');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key], depth + 1)};
  }
  throw const FormatException('Unsupported target data.');
}
