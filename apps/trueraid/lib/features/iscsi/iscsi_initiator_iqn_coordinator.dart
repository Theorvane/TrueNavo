import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_initiator_create_coordinator.dart';
import 'iscsi_write_fence.dart';

final iscsiInitiatorIqnCoordinatorProvider =
    Provider<IscsiInitiatorIqnCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiInitiatorIqnCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiInitiatorIqnOutcome { completed, rejected, unknown }

final class IscsiInitiatorIqnResult {
  const IscsiInitiatorIqnResult(this.outcome, this.message);
  final IscsiInitiatorIqnOutcome outcome;
  final String message;
}

final class IscsiInitiatorIqnReview {
  IscsiInitiatorIqnReview._(
    this.endpoint,
    this.id,
    this.before,
    this.proposed,
    this.comment,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, before, proposed, comment, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation =>
      'REPLACE ISCSI INITIATOR #$id $before WITH $proposed';
}

final class IscsiInitiatorIqnAddReview {
  IscsiInitiatorIqnAddReview._(
    this.endpoint,
    this.id,
    this.before,
    this.proposed,
    this.comment,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, proposed, comment, proof;
  final int id;
  final List<String> before;
  final DateTime issuedAt;
  String get confirmation => 'ADD ISCSI INITIATOR #$id $proposed';
}

final class _Snapshot {
  const _Snapshot(this.groups, this.targets, this.service);
  final List<Object> groups, targets;
  final IscsiServiceStatus service;
  String get proof =>
      jsonEncode([groups, targets, service.state, service.enabledOnBoot]);
  List<Object> group(int id) => groups.cast<List<Object>>().singleWhere(
    (row) => row[0] == id,
    orElse: () => throw StateError('The initiator group is unavailable.'),
  );
  bool references(int id) => targets.cast<List<Object>>().any(
    (target) => (target[4] as List).cast<List<Object?>>().any(
      (access) => access[1] == id,
    ),
  );
}

/// Replaces one IQN in an unreferenced group. Sequential reads cannot exclude
/// another administrator's concurrent writes to the server.
final class IscsiInitiatorIqnCoordinator {
  IscsiInitiatorIqnCoordinator({
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
  final _issued = <IscsiInitiatorIqnReview>{};
  final _addIssued = <IscsiInitiatorIqnAddReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.initiator.query',
        'iscsi.initiator.update',
        'iscsi.target.query',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

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

  Future<_Snapshot> _snapshot() async {
    final rawGroups = await _read('iscsi.initiator.query', const []);
    final rawTargets = await _read('iscsi.target.query', const []);
    if (rawGroups is! List ||
        rawGroups.length >= 100 ||
        rawTargets is! List ||
        rawTargets.length >= 100 ||
        rawGroups.any((row) => row is! Map) ||
        rawTargets.any((row) => row is! Map)) {
      throw StateError('The initiator or target inventory is incomplete.');
    }
    final groups = <Object>[];
    final ids = <int>{};
    for (final item in rawGroups) {
      final row = item as Map;
      final id = row['id'], names = row['initiators'], comment = row['comment'];
      if (id is! int ||
          id < 1 ||
          !ids.add(id) ||
          names is! List ||
          names.length >= 100 ||
          names.any(
            (name) =>
                name is! String ||
                name.isEmpty ||
                name.length > 255 ||
                name == '[truncated]' ||
                name == '[redacted]',
          ) ||
          comment is! String ||
          comment.length > 1024 ||
          comment == '[truncated]' ||
          comment == '[redacted]') {
        throw StateError('The initiator inventory is incomplete.');
      }
      groups.add(<Object>[id, List<String>.from(names), comment]);
    }
    groups.sort(
      (a, b) => ((a as List)[0] as int).compareTo((b as List)[0] as int),
    );
    final targets = <Object>[];
    final targetIds = <int>{};
    for (final item in rawTargets) {
      final row = item as Map;
      final id = row['id'], name = row['name'], mode = row['mode'];
      final access = row['groups'], networks = row['auth_networks'];
      if (id is! int ||
          id < 1 ||
          !targetIds.add(id) ||
          name is! String ||
          name.isEmpty ||
          name.length > 120 ||
          (mode != 'ISCSI' && mode != 'FC' && mode != 'BOTH') ||
          access is! List ||
          access.length >= 100 ||
          access.any((entry) => entry is! Map) ||
          networks is! List ||
          networks.length >= 100 ||
          networks.any(
            (network) => network is! String || network.length > 255,
          )) {
        throw StateError('The target inventory is incomplete.');
      }
      final refs = <Object>[];
      for (final item in access) {
        final entry = item as Map;
        final portal = entry['portal'], initiator = entry['initiator'];
        final method = entry['authmethod'], auth = entry['auth'];
        if (portal is! int ||
            portal < 1 ||
            (initiator != null && (initiator is! int || initiator < 1)) ||
            method is! String ||
            (auth != null && (auth is! int || auth < 1))) {
          throw StateError('The target access inventory is incomplete.');
        }
        refs.add(<Object?>[portal, initiator, method, auth]);
      }
      targets.add(<Object>[id, name, mode, List<String>.from(networks), refs]);
    }
    targets.sort(
      (a, b) => ((a as List)[0] as int).compareTo((b as List)[0] as int),
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
        'Stop iSCSI and disconnect all clients before changing an IQN.',
      );
    }
    final snapshot = _Snapshot(groups, targets, service);
    if (snapshot.proof.length > 32768) {
      throw StateError('The iSCSI dependency inventory is too large.');
    }
    return snapshot;
  }

  List<Object> _candidate(_Snapshot snapshot, int id, String proposed) {
    final row = snapshot.group(id);
    final names = row[1] as List<String>;
    if (names.length != 1 ||
        !IscsiInitiatorCreateCoordinator.validIqn(names.single)) {
      throw StateError(
        'Only a group with one explicit lowercase IQN is supported.',
      );
    }
    if (snapshot.references(id)) {
      throw StateError(
        'Remove target references independently before changing the IQN.',
      );
    }
    if (names.single == proposed ||
        snapshot.groups.cast<List<Object>>().any(
          (other) => (other[1] as List<String>).contains(proposed),
        )) {
      throw StateError('The proposed IQN is already configured.');
    }
    return row;
  }

  List<Object> _addCandidate(_Snapshot snapshot, int id, String proposed) {
    final row = snapshot.group(id);
    final names = row[1] as List<String>;
    if (names.length >= 10 ||
        names.toSet().length != names.length ||
        names.any((name) => !IscsiInitiatorCreateCoordinator.validIqn(name))) {
      throw StateError(
        'Only groups with fewer than ten explicit lowercase IQNs are supported.',
      );
    }
    if (snapshot.references(id)) {
      throw StateError(
        'Remove target references independently before adding an IQN.',
      );
    }
    if (snapshot.groups.cast<List<Object>>().any(
      (other) => (other[1] as List<String>).contains(proposed),
    )) {
      throw StateError('The proposed IQN is already configured.');
    }
    return row;
  }

  Future<IscsiInitiatorIqnAddReview> prepareAdd(int id, String proposed) async {
    _guard();
    if (!available ||
        _busy ||
        id < 1 ||
        !IscsiInitiatorCreateCoordinator.validIqn(proposed)) {
      throw StateError('Choose a group and enter one lowercase IQN.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    _addIssued.clear();
    try {
      final snapshot = await _snapshot();
      final row = _addCandidate(snapshot, id, proposed);
      final review = IscsiInitiatorIqnAddReview._(
        session.endpoint!,
        id,
        List<String>.from(row[1] as List<String>),
        proposed,
        row[2] as String,
        snapshot.proof,
        _now().toUtc(),
      );
      _addIssued.add(review);
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

  void cancelAdd(IscsiInitiatorIqnAddReview review) =>
      _addIssued.remove(review);

  Future<IscsiInitiatorIqnResult> executeAdd(
    IscsiInitiatorIqnAddReview review,
    String confirmation,
  ) async {
    final issued = _addIssued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        _busy ||
        !isCurrent() ||
        IscsiWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const IscsiInitiatorIqnResult(
        IscsiInitiatorIqnOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiInitiatorIqnResult(
        IscsiInitiatorIqnOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _addCandidate(before, review.id, review.proposed);
      if (before.proof != review.proof) {
        return const IscsiInitiatorIqnResult(
          IscsiInitiatorIqnOutcome.rejected,
          'Initiator, target or service state changed since review. Nothing was sent.',
        );
      }
      final expectedNames = <String>[...review.before, review.proposed];
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.initiator.update'),
          arguments: [
            review.id,
            {'initiators': expectedNames},
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiInitiatorIqnResult(
          IscsiInitiatorIqnOutcome.rejected,
          'The server denied the update. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted) return _unknown();
      final response = result.value;
      if (response is! Map ||
          response['id'] != review.id ||
          jsonEncode(response['initiators']) != jsonEncode(expectedNames) ||
          response['comment'] != review.comment) {
        return _unknown();
      }
      final after = await _snapshot();
      final expected = <Object>[
        for (final item in before.groups)
          if ((item as List)[0] == review.id)
            <Object>[review.id, expectedNames, review.comment]
          else
            item,
      ];
      if (jsonEncode(after.groups) != jsonEncode(expected) ||
          jsonEncode(after.targets) != jsonEncode(before.targets) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot) {
        return _unknown();
      }
      return const IscsiInitiatorIqnResult(
        IscsiInitiatorIqnOutcome.completed,
        'The new IQN and preserved existing list matched a fresh inventory read.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiInitiatorIqnResult(
              IscsiInitiatorIqnOutcome.rejected,
              'The initiator preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<IscsiInitiatorIqnReview> prepare(int id, String proposed) async {
    _guard();
    if (!available ||
        _busy ||
        id < 1 ||
        !IscsiInitiatorCreateCoordinator.validIqn(proposed)) {
      throw StateError('Choose a group and enter one lowercase IQN.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    _addIssued.clear();
    try {
      final snapshot = await _snapshot();
      final row = _candidate(snapshot, id, proposed);
      final review = IscsiInitiatorIqnReview._(
        session.endpoint!,
        id,
        (row[1] as List<String>).single,
        proposed,
        row[2] as String,
        snapshot.proof,
        _now().toUtc(),
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

  void cancel(IscsiInitiatorIqnReview review) => _issued.remove(review);

  Future<IscsiInitiatorIqnResult> execute(
    IscsiInitiatorIqnReview review,
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
      return const IscsiInitiatorIqnResult(
        IscsiInitiatorIqnOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiInitiatorIqnResult(
        IscsiInitiatorIqnOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _candidate(before, review.id, review.proposed);
      if (before.proof != review.proof) {
        return const IscsiInitiatorIqnResult(
          IscsiInitiatorIqnOutcome.rejected,
          'Initiator, target or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.initiator.update'),
          arguments: [
            review.id,
            {
              'initiators': [review.proposed],
            },
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiInitiatorIqnResult(
          IscsiInitiatorIqnOutcome.rejected,
          'The server denied the update. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted) return _unknown();
      final response = result.value;
      if (response is! Map ||
          response['id'] != review.id ||
          jsonEncode(response['initiators']) != jsonEncode([review.proposed]) ||
          response['comment'] != review.comment) {
        return _unknown();
      }
      final after = await _snapshot();
      final expected = <Object>[
        for (final item in before.groups)
          if ((item as List)[0] == review.id)
            <Object>[
              review.id,
              <String>[review.proposed],
              review.comment,
            ]
          else
            item,
      ];
      if (jsonEncode(after.groups) != jsonEncode(expected) ||
          jsonEncode(after.targets) != jsonEncode(before.targets) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot) {
        return _unknown();
      }
      return const IscsiInitiatorIqnResult(
        IscsiInitiatorIqnOutcome.completed,
        'The new IQN matched a fresh inventory read; target associations were unchanged.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiInitiatorIqnResult(
              IscsiInitiatorIqnOutcome.rejected,
              'The initiator preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiInitiatorIqnResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    _addIssued.clear();
    return const IscsiInitiatorIqnResult(
      IscsiInitiatorIqnOutcome.unknown,
      'The IQN update may have changed the server. Do not retry; inspect the server and reconnect.',
    );
  }
}
