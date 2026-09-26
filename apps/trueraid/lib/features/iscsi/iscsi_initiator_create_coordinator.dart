import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiInitiatorCreateCoordinatorProvider =
    Provider<IscsiInitiatorCreateCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiInitiatorCreateCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiInitiatorCreateOutcome { completed, rejected, unknown }

final class IscsiInitiatorCreateResult {
  const IscsiInitiatorCreateResult(this.outcome, this.message);
  final IscsiInitiatorCreateOutcome outcome;
  final String message;
}

final class IscsiInitiatorCreateReview {
  IscsiInitiatorCreateReview._({
    required this.endpoint,
    required this.iqn,
    required this.comment,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, iqn, comment, proof;
  final DateTime issuedAt;
  String get confirmation => 'CREATE ISCSI INITIATOR $iqn';
}

final class _InitiatorRow {
  const _InitiatorRow(this.id, this.names, this.comment);
  final int id;
  final List<String> names;
  final String comment;
  Object get proof => [id, names, comment];
}

final class _Snapshot {
  const _Snapshot(this.initiators, this.targets, this.service);
  final List<_InitiatorRow> initiators;
  final List<Object> targets;
  final IscsiServiceStatus service;
  String get proof => jsonEncode([
    for (final row in initiators) row.proof,
    targets,
    service.state,
    service.enabledOnBoot,
  ]);
}

/// Creates one explicit IQN group without assigning it to any target.
/// Sequential server reads cannot exclude external concurrent edits.
final class IscsiInitiatorCreateCoordinator {
  IscsiInitiatorCreateCoordinator({
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
  final _issued = <IscsiInitiatorCreateReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.initiator.query',
        'iscsi.initiator.create',
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
    final rawInitiators = await _read('iscsi.initiator.query', const []);
    final rawTargets = await _read('iscsi.target.query', const []);
    if (rawInitiators is! List ||
        rawInitiators.length >= 100 ||
        rawTargets is! List ||
        rawTargets.length >= 100 ||
        rawInitiators.any((row) => row is! Map) ||
        rawTargets.any((row) => row is! Map)) {
      throw StateError('The initiator or target inventory is incomplete.');
    }
    final initiators = <_InitiatorRow>[];
    final initiatorIds = <int>{};
    for (final item in rawInitiators) {
      final row = item as Map;
      final id = row['id'];
      final names = row['initiators'];
      final comment = row['comment'];
      if (id is! int ||
          id < 1 ||
          !initiatorIds.add(id) ||
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
      initiators.add(_InitiatorRow(id, List<String>.from(names), comment));
    }
    initiators.sort((a, b) => a.id.compareTo(b.id));
    final targets = <Object>[];
    final targetIds = <int>{};
    for (final item in rawTargets) {
      final row = item as Map;
      final id = row['id'];
      final name = row['name'];
      final mode = row['mode'];
      final groups = row['groups'];
      final networks = row['auth_networks'];
      if (id is! int ||
          id < 1 ||
          !targetIds.add(id) ||
          name is! String ||
          name.isEmpty ||
          name.length > 120 ||
          (mode != 'ISCSI' && mode != 'FC' && mode != 'BOTH') ||
          groups is! List ||
          groups.length >= 100 ||
          groups.any((group) => group is! Map) ||
          networks is! List ||
          networks.length >= 100 ||
          networks.any(
            (network) => network is! String || network.length > 255,
          )) {
        throw StateError('The target inventory is incomplete.');
      }
      final refs = <Object>[];
      for (final item in groups) {
        final group = item as Map;
        final portal = group['portal'];
        final initiator = group['initiator'];
        final authMethod = group['authmethod'];
        final auth = group['auth'];
        if (portal is! int ||
            portal < 1 ||
            (initiator != null && (initiator is! int || initiator < 1)) ||
            authMethod is! String ||
            (auth != null && (auth is! int || auth < 1))) {
          throw StateError('The target access inventory is incomplete.');
        }
        refs.add([portal, initiator, authMethod, auth]);
      }
      targets.add([id, name, mode, networks, refs]);
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
        'Stop iSCSI and disconnect all clients before creating a group.',
      );
    }
    final snapshot = _Snapshot(initiators, targets, service);
    if (snapshot.proof.length > 32768) {
      throw StateError('The iSCSI dependency inventory is too large.');
    }
    return snapshot;
  }

  static bool validIqn(String iqn) =>
      iqn.length <= 223 &&
      RegExp(
        r'^iqn\.(?:19|20)\d{2}-(?:0[1-9]|1[0-2])\.[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:\:[a-z0-9.:-]+)?$',
      ).hasMatch(iqn);

  Future<IscsiInitiatorCreateReview> prepare(String iqn, String comment) async {
    _guard();
    if (!available ||
        _busy ||
        !validIqn(iqn) ||
        comment.length > 128 ||
        comment.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError(
        'Enter one lowercase IQN and a comment of at most 128 characters.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final before = await _snapshot();
      if (before.initiators.length >= 99) {
        throw StateError(
          'The bounded initiator inventory cannot verify another group.',
        );
      }
      if (before.initiators.any((row) => row.names.contains(iqn))) {
        throw StateError(
          'This IQN is already configured in an initiator group.',
        );
      }
      final review = IscsiInitiatorCreateReview._(
        endpoint: session.endpoint!,
        iqn: iqn,
        comment: comment,
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

  void cancel(IscsiInitiatorCreateReview review) => _issued.remove(review);

  Future<IscsiInitiatorCreateResult> execute(
    IscsiInitiatorCreateReview review,
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
      return const IscsiInitiatorCreateResult(
        IscsiInitiatorCreateOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiInitiatorCreateResult(
        IscsiInitiatorCreateOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      if (before.proof != review.proof || before.initiators.length >= 99) {
        return const IscsiInitiatorCreateResult(
          IscsiInitiatorCreateOutcome.rejected,
          'Initiator, target or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.initiator.create'),
          arguments: [
            {
              'initiators': [review.iqn],
              'comment': review.comment,
            },
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiInitiatorCreateResult(
          IscsiInitiatorCreateOutcome.rejected,
          'The server denied creation. No group was confirmed.',
        );
      }
      if (result is! AdminCompleted || result.value is! Map) return _unknown();
      final created = result.value as Map;
      final id = created['id'];
      if (id is! int ||
          id < 1 ||
          created['comment'] != review.comment ||
          created['initiators'] is! List ||
          jsonEncode(created['initiators']) != jsonEncode([review.iqn])) {
        return _unknown();
      }
      final after = await _snapshot();
      final matches = after.initiators.where((row) => row.id == id).toList();
      if (matches.length != 1 ||
          matches.single.comment != review.comment ||
          jsonEncode(matches.single.names) != jsonEncode([review.iqn]) ||
          after.initiators.length != before.initiators.length + 1 ||
          jsonEncode(after.targets) != jsonEncode(before.targets) ||
          after.targets.any(
            (target) => ((target as List)[4] as List).any(
              (group) => (group as List)[1] == id,
            ),
          ) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot ||
          jsonEncode([
                for (final row in after.initiators)
                  if (row.id != id) row.proof,
              ]) !=
              jsonEncode([for (final row in before.initiators) row.proof])) {
        return _unknown();
      }
      return IscsiInitiatorCreateResult(
        IscsiInitiatorCreateOutcome.completed,
        'Initiator group #$id was found in a fresh inventory with no target association. Client access was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiInitiatorCreateResult(
              IscsiInitiatorCreateOutcome.rejected,
              'The initiator preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiInitiatorCreateResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiInitiatorCreateResult(
      IscsiInitiatorCreateOutcome.unknown,
      'Creation may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
