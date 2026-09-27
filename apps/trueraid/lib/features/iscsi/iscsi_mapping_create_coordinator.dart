import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiMappingCreateCoordinatorProvider =
    Provider<IscsiMappingCreateCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiMappingCreateCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiMappingCreateOutcome { completed, rejected, unknown }

final class IscsiMappingCreateResult {
  const IscsiMappingCreateResult(this.outcome, this.message);
  final IscsiMappingCreateOutcome outcome;
  final String message;
}

final class IscsiMappingCreateReview {
  IscsiMappingCreateReview._(
    this.endpoint,
    this.targetId,
    this.targetName,
    this.extentId,
    this.extentName,
    this.lun,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, targetName, extentName, proof;
  final int targetId, extentId, lun;
  final DateTime issuedAt;
  String get confirmation =>
      'MAP ISCSI TARGET #$targetId EXTENT #$extentId LUN $lun';
}

final class IscsiMappingRenumberReview {
  IscsiMappingRenumberReview._(
    this.endpoint,
    this.mappingId,
    this.targetId,
    this.targetName,
    this.extentId,
    this.extentName,
    this.beforeLun,
    this.proposedLun,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, targetName, extentName, proof;
  final int mappingId, targetId, extentId, beforeLun, proposedLun;
  final DateTime issuedAt;
  String get confirmation =>
      'MOVE ISCSI LUN #$mappingId $beforeLun TO $proposedLun';
}

final class _Snapshot {
  const _Snapshot(
    this.targets,
    this.extents,
    this.availableTargets,
    this.availableExtents,
    this.mappings,
    this.targetDigest,
    this.extentDigest,
    this.service,
  );
  final Map<int, String> targets, extents;
  final Set<int> availableTargets, availableExtents;
  final List<List<int>> mappings;
  final String targetDigest, extentDigest;
  final IscsiServiceStatus service;
  String get proof => jsonEncode([
    targetDigest,
    extentDigest,
    mappings,
    service.state,
    service.enabledOnBoot,
  ]);
}

/// Maps one unused extent to an unbound iSCSI-only target at an explicit LUN.
/// Sequential reads cannot exclude another administrator's concurrent writes.
final class IscsiMappingCreateCoordinator {
  IscsiMappingCreateCoordinator({
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
  final _issued = <IscsiMappingCreateReview>{};
  final _renumberIssued = <IscsiMappingRenumberReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.target.query',
        'iscsi.extent.query',
        'iscsi.targetextent.query',
        'iscsi.targetextent.create',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  bool get renumberAvailable =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.target.query',
        'iscsi.extent.query',
        'iscsi.targetextent.query',
        'iscsi.targetextent.update',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!api.adminCatalog.versionSupported ||
        method == null ||
        !method.supported) {
      throw StateError('Required iSCSI mapping methods are unavailable.');
    }
    return method;
  }

  void _guard() {
    if (!isCurrent() || session.endpoint == null) {
      throw StateError('The server connection changed.');
    }
    if (IscsiWriteFence.isUncertain(session)) {
      throw StateError(
        'An iSCSI change is unverified. Reconnect before editing.',
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
      throw StateError('The iSCSI mapping preflight is unavailable.');
    }
    return result.value;
  }

  ({Map<int, String> labels, Set<int> eligible, String digest}) _inventory(
    Object? raw,
    String kind,
  ) {
    if (raw is! List || raw.length >= 100 || raw.any((item) => item is! Map)) {
      throw StateError('The $kind inventory is incomplete.');
    }
    final rows = <Map>[];
    final labels = <int, String>{};
    final eligible = <int>{};
    for (final item in raw) {
      final row = item as Map;
      final id = row['id'], name = row['name'];
      if (id is! int ||
          id < 1 ||
          labels.containsKey(id) ||
          name is! String ||
          name.isEmpty ||
          name.length > 120 ||
          name == '[truncated]' ||
          name == '[redacted]') {
        throw StateError('The $kind inventory is incomplete.');
      }
      if (kind == 'target') {
        final mode = row['mode'];
        final groups = row['groups'], networks = row['auth_networks'];
        if (!['ISCSI', 'FC', 'BOTH'].contains(mode) ||
            groups is! List ||
            groups.length >= 100 ||
            networks is! List ||
            networks.length >= 100) {
          throw StateError('The target inventory is incomplete.');
        }
        if (mode == 'ISCSI' && groups.isEmpty && networks.isEmpty) {
          eligible.add(id);
        }
      } else {
        if (row['type'] == 'DISK' || row['type'] == 'FILE') {
          if (row['enabled'] == true && row['locked'] == false) {
            eligible.add(id);
          }
        }
      }
      labels[id] = name;
      rows.add(row);
    }
    rows.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    final encoded = jsonEncode(rows);
    if (encoded.length > 262144 ||
        encoded.contains('[truncated]') ||
        encoded.contains('[redacted]')) {
      throw StateError('The $kind inventory is incomplete.');
    }
    return (
      labels: labels,
      eligible: eligible,
      digest: sha256.convert(utf8.encode(encoded)).toString(),
    );
  }

  Future<_Snapshot> _snapshot() async {
    final targetInventory = _inventory(
      await _read('iscsi.target.query', const []),
      'target',
    );
    final extentInventory = _inventory(
      await _read('iscsi.extent.query', const []),
      'extent',
    );
    final rawMappings = await _read('iscsi.targetextent.query', const []);
    if (rawMappings is! List ||
        rawMappings.length >= 100 ||
        rawMappings.any((item) => item is! Map)) {
      throw StateError('The LUN mapping inventory is incomplete.');
    }
    final mappings = <List<int>>[];
    final ids = <int>{};
    for (final item in rawMappings) {
      final row = item as Map;
      final id = row['id'], target = row['target'];
      final extent = row['extent'], lun = row['lunid'];
      if (id is! int ||
          id < 1 ||
          !ids.add(id) ||
          target is! int ||
          !targetInventory.labels.containsKey(target) ||
          extent is! int ||
          !extentInventory.labels.containsKey(extent) ||
          lun is! int ||
          lun < 0) {
        throw StateError('The LUN mapping inventory is incomplete.');
      }
      mappings.add([id, target, extent, lun]);
    }
    mappings.sort((a, b) => a.first.compareTo(b.first));
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
        'Stop iSCSI and disconnect all clients before mapping a LUN.',
      );
    }
    final snapshot = _Snapshot(
      targetInventory.labels,
      extentInventory.labels,
      targetInventory.eligible,
      extentInventory.eligible,
      mappings,
      targetInventory.digest,
      extentInventory.digest,
      service,
    );
    if (snapshot.proof.length > 32768) {
      throw StateError('The iSCSI dependency inventory is too large.');
    }
    return snapshot;
  }

  void _candidate(_Snapshot snapshot, int targetId, int extentId, int lun) {
    if (!snapshot.availableTargets.contains(targetId)) {
      throw StateError('Only an unbound iSCSI-only target is supported.');
    }
    if (!snapshot.availableExtents.contains(extentId)) {
      throw StateError('Choose an enabled, unlocked disk or file extent.');
    }
    if (lun < 0 || lun > 31) {
      throw StateError('Choose a LUN number between 0 and 31.');
    }
    final targetMappings = snapshot.mappings
        .where((mapping) => mapping[1] == targetId)
        .toList();
    final usedLuns = targetMappings.map((mapping) => mapping[3]).toSet();
    if (targetMappings.length >= 32 ||
        targetMappings.any((mapping) => mapping[3] > 31) ||
        usedLuns.length != targetMappings.length ||
        (targetMappings.isEmpty && lun != 0) ||
        (targetMappings.isNotEmpty && (!usedLuns.contains(0) || lun == 0)) ||
        usedLuns.contains(lun)) {
      throw StateError('The requested LUN is unavailable on this target.');
    }
    if (snapshot.mappings.any((mapping) => mapping[2] == extentId)) {
      throw StateError('The extent is already mapped.');
    }
  }

  List<int> _renumberCandidate(
    _Snapshot snapshot,
    int mappingId,
    int proposed,
  ) {
    if (proposed < 1 || proposed > 31) {
      throw StateError('Choose a free LUN number from 1 to 31.');
    }
    final matches = snapshot.mappings
        .where((mapping) => mapping[0] == mappingId)
        .toList();
    if (matches.length != 1) {
      throw StateError('The LUN mapping is unavailable.');
    }
    final selected = matches.single;
    final targetId = selected[1], extentId = selected[2], oldLun = selected[3];
    if (!snapshot.availableTargets.contains(targetId) ||
        !snapshot.availableExtents.contains(extentId)) {
      throw StateError(
        'Only an unbound iSCSI target and unlocked active extent qualify.',
      );
    }
    final targetMappings = snapshot.mappings
        .where((mapping) => mapping[1] == targetId)
        .toList();
    final usedLuns = targetMappings.map((mapping) => mapping[3]).toSet();
    if (targetMappings.length < 2 ||
        targetMappings.length > 32 ||
        usedLuns.length != targetMappings.length ||
        targetMappings.any((mapping) => mapping[3] > 31) ||
        !usedLuns.contains(0) ||
        oldLun < 1 ||
        oldLun > 31 ||
        usedLuns.contains(proposed) ||
        snapshot.mappings.any(
          (mapping) => mapping[0] != mappingId && mapping[2] == extentId,
        )) {
      throw StateError('The selected or destination LUN is unavailable.');
    }
    return selected;
  }

  Future<IscsiMappingRenumberReview> prepareRenumber(
    int mappingId,
    int proposedLun,
  ) async {
    _guard();
    if (!renumberAvailable ||
        _busy ||
        mappingId < 1 ||
        proposedLun < 1 ||
        proposedLun > 31) {
      throw StateError(
        'Choose an existing additional LUN and a free number 1–31.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    _renumberIssued.clear();
    try {
      final snapshot = await _snapshot();
      final mapping = _renumberCandidate(snapshot, mappingId, proposedLun);
      final review = IscsiMappingRenumberReview._(
        session.endpoint!,
        mappingId,
        mapping[1],
        snapshot.targets[mapping[1]]!,
        mapping[2],
        snapshot.extents[mapping[2]]!,
        mapping[3],
        proposedLun,
        snapshot.proof,
        _now().toUtc(),
      );
      _renumberIssued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The LUN preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancelRenumber(IscsiMappingRenumberReview review) =>
      _renumberIssued.remove(review);

  Future<IscsiMappingCreateResult> executeRenumber(
    IscsiMappingRenumberReview review,
    String confirmation,
  ) async {
    final issued = _renumberIssued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        _busy ||
        !isCurrent() ||
        IscsiWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const IscsiMappingCreateResult(
        IscsiMappingCreateOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiMappingCreateResult(
        IscsiMappingCreateOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _renumberCandidate(before, review.mappingId, review.proposedLun);
      if (before.proof != review.proof) {
        return const IscsiMappingCreateResult(
          IscsiMappingCreateOutcome.rejected,
          'Target, extent, LUN or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.targetextent.update'),
          arguments: [
            review.mappingId,
            {'lunid': review.proposedLun},
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiMappingCreateResult(
          IscsiMappingCreateOutcome.rejected,
          'The server denied the LUN change. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted) {
        return _unknown();
      }
      final response = result.value;
      if (response is! Map ||
          response['id'] != review.mappingId ||
          response['target'] != review.targetId ||
          response['extent'] != review.extentId ||
          response['lunid'] != review.proposedLun) {
        return _unknown();
      }
      final after = await _snapshot();
      final expected = <List<int>>[
        for (final mapping in before.mappings)
          if (mapping[0] == review.mappingId)
            [mapping[0], mapping[1], mapping[2], review.proposedLun]
          else
            mapping,
      ];
      if (after.targetDigest != before.targetDigest ||
          after.extentDigest != before.extentDigest ||
          jsonEncode(after.mappings) != jsonEncode(expected) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot) {
        return _unknown();
      }
      return const IscsiMappingCreateResult(
        IscsiMappingCreateOutcome.completed,
        'Only the reviewed LUN number changed; target, extent and other mappings stayed unchanged.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiMappingCreateResult(
              IscsiMappingCreateOutcome.rejected,
              'The LUN preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<IscsiMappingCreateReview> prepare(
    int targetId,
    int extentId, {
    int lun = 0,
  }) async {
    _guard();
    if (!available ||
        _busy ||
        targetId < 1 ||
        extentId < 1 ||
        lun < 0 ||
        lun > 31) {
      throw StateError('Choose a target, an extent and LUN 0–31 to review.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    _renumberIssued.clear();
    try {
      final snapshot = await _snapshot();
      _candidate(snapshot, targetId, extentId, lun);
      final review = IscsiMappingCreateReview._(
        session.endpoint!,
        targetId,
        snapshot.targets[targetId]!,
        extentId,
        snapshot.extents[extentId]!,
        lun,
        snapshot.proof,
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The LUN mapping preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiMappingCreateReview review) => _issued.remove(review);

  Future<IscsiMappingCreateResult> execute(
    IscsiMappingCreateReview review,
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
      return const IscsiMappingCreateResult(
        IscsiMappingCreateOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiMappingCreateResult(
        IscsiMappingCreateOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _candidate(before, review.targetId, review.extentId, review.lun);
      if (before.proof != review.proof) {
        return const IscsiMappingCreateResult(
          IscsiMappingCreateOutcome.rejected,
          'Target, extent, LUN or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.targetextent.create'),
          arguments: [
            {
              'target': review.targetId,
              'extent': review.extentId,
              'lunid': review.lun,
            },
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiMappingCreateResult(
          IscsiMappingCreateOutcome.rejected,
          'The server denied the mapping. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted) return _unknown();
      final response = result.value;
      if (response is! Map ||
          response['id'] is! int ||
          (response['id'] as int) < 1 ||
          response['target'] != review.targetId ||
          response['extent'] != review.extentId ||
          response['lunid'] != review.lun) {
        return _unknown();
      }
      final newId = response['id'] as int;
      if (before.mappings.any((mapping) => mapping[0] == newId)) {
        return _unknown();
      }
      final after = await _snapshot();
      final expected = <List<int>>[
        ...before.mappings,
        [newId, review.targetId, review.extentId, review.lun],
      ]..sort((a, b) => a.first.compareTo(b.first));
      if (after.targetDigest != before.targetDigest ||
          after.extentDigest != before.extentDigest ||
          jsonEncode(after.mappings) != jsonEncode(expected) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot) {
        return _unknown();
      }
      return IscsiMappingCreateResult(
        IscsiMappingCreateOutcome.completed,
        'Only the reviewed LUN ${review.lun} mapping appeared; target and extent settings were unchanged.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiMappingCreateResult(
              IscsiMappingCreateOutcome.rejected,
              'The LUN mapping preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiMappingCreateResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    _renumberIssued.clear();
    return const IscsiMappingCreateResult(
      IscsiMappingCreateOutcome.unknown,
      'The mapping may have changed the server. Do not retry; inspect the server and reconnect.',
    );
  }
}
