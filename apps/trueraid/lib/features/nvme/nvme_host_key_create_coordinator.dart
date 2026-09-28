import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeHostKeyCreateCoordinatorProvider =
    Provider.autoDispose<NvmeHostKeyCreateCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession ||
          repository is! AuthenticatedNvmeHostKeyCreateSession ||
          repository is! AuthenticatedNvmeHostChoicesSession ||
          repository is! AuthenticatedNvmeHostAuthenticationClearSession) {
        return null;
      }
      final coordinator = NvmeHostKeyCreateCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        createApi: repository as AuthenticatedNvmeHostKeyCreateSession,
        choicesApi: repository as AuthenticatedNvmeHostChoicesSession,
        targetApi:
            repository as AuthenticatedNvmeHostAuthenticationClearSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            ref.mounted &&
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

enum NvmeHostKeyCreateOutcome { completed, rejected, unknown }

final class NvmeHostKeyCreateResult {
  const NvmeHostKeyCreateResult(this.outcome, this.message);
  final NvmeHostKeyCreateOutcome outcome;
  final String message;
}

final class NvmeHostKeyCreateReview {
  NvmeHostKeyCreateReview._(
    this.endpoint,
    this.nqn,
    this.hash,
    this.group,
    this._keys,
    this.proof,
    this.issuedAt,
  ) : hasControllerKey = _keys.hasControllerKey;
  final String endpoint, nqn, hash, proof;
  final String? group;
  final bool hasControllerKey;
  final DateTime issuedAt;
  final NvmeHostKeyDraft _keys;
  bool get hasKeys => !_keys.isDisposed;
  String get confirmation => 'REGISTER NVME HOST $nqn WITH IMPORTED KEYS';
}

/// Owns drafts from prepare through terminal execution or cancellation.
/// No subsystem association is created. Sequential checks cannot exclude other
/// administrators or attest key validity, runtime authentication or access.
final class NvmeHostKeyCreateCoordinator {
  NvmeHostKeyCreateCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.createApi,
    required this.choicesApi,
    required this.targetApi,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final AuthenticatedNvmeHostKeyCreateSession createApi;
  final AuthenticatedNvmeHostChoicesSession choicesApi;
  final AuthenticatedNvmeHostAuthenticationClearSession targetApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmeHostKeyCreateReview>{};
  NvmeHostKeyDraft? _active;
  bool _busy = false, _closed = false;
  bool get locked => _busy || _closed || NvmeWriteFence.isUncertain(session);
  bool get available =>
      !_closed &&
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('nvmet.host.create') != null &&
      api.adminCatalog.method('nvmet.host.query') != null &&
      [
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.host_subsys.query',
        'nvmet.host.dhchap_hash_choices',
        'nvmet.host.dhchap_dhgroup_choices',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void _guard() {
    if (_closed || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError(
        'Connection changed or an NVMe change is unverified. Nothing was sent.',
      );
    }
  }

  void _cancelAll() {
    for (final review in _issued) {
      review._keys.dispose();
    }
    _issued.clear();
  }

  void dispose() {
    _closed = true;
    _cancelAll();
    _active?.dispose();
  }

  void cancel(NvmeHostKeyCreateReview review) {
    if (_issued.remove(review)) review._keys.dispose();
  }

  Future<NvmeMutationSnapshot> _snapshot() async {
    final NvmeMutationSnapshot value;
    try {
      value = await NvmeMutationSnapshot.load(
        api: api,
        hostsApi: hostsApi,
        isCurrent: isCurrent,
      );
    } on Object {
      throw StateError('NVMe inventory preflight failed. Nothing was sent.');
    }
    _guard();
    return value;
  }

  Future<void> _choices(String hash, String? group) async {
    final NvmeHostAuthenticationChoices choices;
    try {
      choices = await choicesApi.loadNvmeHostAuthenticationChoices();
    } on Object {
      throw StateError('Algorithm discovery failed. Nothing was sent.');
    }
    _guard();
    if (!choices.hashes.contains(hash) ||
        (group != null && !choices.groups.contains(group))) {
      throw StateError(
        'The server does not advertise these algorithm choices. Nothing was sent.',
      );
    }
  }

  void _validate(NvmeMutationSnapshot value, String nqn) {
    if (value.hosts.hosts.length >= 99 ||
        value.hosts.hosts.any(
          (h) => h.nqn.toLowerCase() == nqn.toLowerCase(),
        )) {
      throw StateError(
        'Duplicate NQN or bounded inventory limit. Nothing was sent.',
      );
    }
  }

  Future<NvmeHostKeyCreateReview> prepare(
    String nqn, {
    required String hash,
    required String? group,
    required NvmeHostKeyDraft keys,
  }) async {
    // Reuse must not destroy a draft already owned by an active operation or review.
    if (identical(keys, _active) ||
        _issued.any((r) => identical(r._keys, keys))) {
      throw StateError(
        'Imported keys already belong to another review or operation.',
      );
    }
    var retained = false;
    Object? owner;
    try {
      _guard();
      if (!available ||
          _busy ||
          !isSupportedNvmeHostNqn(nqn) ||
          keys.isDisposed ||
          !const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(hash) ||
          (group != null &&
              !const {
                '2048-BIT',
                '3072-BIT',
                '4096-BIT',
                '6144-BIT',
                '8192-BIT',
              }.contains(group))) {
        throw StateError(
          'Enter supported NQN, algorithm settings and imported keys. Nothing was sent.',
        );
      }
      owner = lock.acquire();
      if (owner == null) {
        throw StateError('Another server operation is in progress.');
      }
      _busy = true;
      _cancelAll();
      _active = keys;
      await _choices(hash, group);
      final value = await _snapshot();
      _validate(value, nqn);
      if (keys.isDisposed) {
        throw StateError('Imported keys were discarded. Nothing was sent.');
      }
      final review = NvmeHostKeyCreateReview._(
        session.endpoint!,
        nqn,
        hash,
        group,
        keys,
        value.proof(),
        _now().toUtc(),
      );
      _issued.add(review);
      retained = true;
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('NVMe host preflight failed. Nothing was sent.');
    } finally {
      if (!retained) keys.dispose();
      if (owner != null) {
        _active = null;
        _busy = false;
        lock.release(owner);
      }
    }
  }

  Future<NvmeHostKeyCreateResult> execute(
    NvmeHostKeyCreateReview review,
    String phrase, {
    bool acknowledgeKeyLimitations = false,
    bool acknowledgeNoAssociation = false,
  }) async {
    final issued = _issued.remove(review);
    // A foreign/replayed review never disposes someone else's active draft.
    if (!issued) {
      return const NvmeHostKeyCreateResult(
        NvmeHostKeyCreateOutcome.rejected,
        'Review is invalid. Nothing was sent.',
      );
    }
    Object? owner;
    var sent = false;
    try {
      final now = _now().toUtc();
      if (_busy ||
          !available ||
          !isCurrent() ||
          NvmeWriteFence.isUncertain(session) ||
          !review.hasKeys ||
          review.endpoint != session.endpoint ||
          phrase != review.confirmation ||
          !acknowledgeKeyLimitations ||
          !acknowledgeNoAssociation ||
          now.isBefore(review.issuedAt) ||
          now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
        return const NvmeHostKeyCreateResult(
          NvmeHostKeyCreateOutcome.rejected,
          'Review, consent or confirmation is invalid. Nothing was sent.',
        );
      }
      owner = lock.acquire();
      if (owner == null) {
        return const NvmeHostKeyCreateResult(
          NvmeHostKeyCreateOutcome.rejected,
          'Another server operation is in progress. Nothing was sent.',
        );
      }
      _busy = true;
      _active = review._keys;
      await _choices(review.hash, review.group);
      final before = await _snapshot();
      _validate(before, review.nqn);
      final prewriteTime = _now().toUtc();
      if (before.proof() != review.proof ||
          !review.hasKeys ||
          prewriteTime.isBefore(review.issuedAt) ||
          prewriteTime.difference(review.issuedAt) >=
              const Duration(minutes: 5)) {
        return const NvmeHostKeyCreateResult(
          NvmeHostKeyCreateOutcome.rejected,
          'NVMe configuration changed or the review expired. Nothing was sent.',
        );
      }
      sent = true;
      final created = await createApi.createNvmeHostWithImportedKeys(
        hostNqn: review.nqn,
        hash: review.hash,
        group: review.group,
        keys: review._keys,
      );
      _guard();
      if (created.id <= 0 ||
          created.nqn != review.nqn ||
          created.hash != review.hash ||
          created.group != review.group ||
          !created.hostKeyReturned ||
          created.controllerKeyReturned != review.hasControllerKey ||
          before.hosts.hosts.any((h) => h.id == created.id)) {
        return _unknown();
      }
      final after = await _snapshot();
      final refreshed = await targetApi.loadNvmeHostAuthenticationTarget(
        created.id,
      );
      _guard();
      if (!refreshed.sameReturnedSettings(created) ||
          after.hosts.hosts.length != before.hosts.hosts.length + 1 ||
          after.hosts.hosts
                  .where((h) => h.id == created.id && h.nqn == review.nqn)
                  .length !=
              1 ||
          after.hosts.mappings.any((m) => m.hostId == created.id) ||
          after.proof(omitHostId: created.id) != before.proof()) {
        return _unknown();
      }
      return NvmeHostKeyCreateResult(
        NvmeHostKeyCreateOutcome.completed,
        'Host #${created.id} was found with reviewed public authentication metadata and no subsystem mapping. The SDK checked exact saved key values. Key validity, initiator compatibility, runtime authentication and access were not verified.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostKeyCreateResult(
              NvmeHostKeyCreateOutcome.rejected,
              'NVMe host preflight failed. Nothing was sent.',
            );
    } finally {
      review._keys.dispose();
      if (owner != null) {
        _active = null;
        _busy = false;
        lock.release(owner);
      }
    }
  }

  NvmeHostKeyCreateResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _cancelAll();
    return const NvmeHostKeyCreateResult(
      NvmeHostKeyCreateOutcome.unknown,
      'Host registration may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
