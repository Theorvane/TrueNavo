import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeHostKeyReplaceCoordinatorProvider =
    Provider.autoDispose<NvmeHostKeyReplaceCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession ||
          repository is! AuthenticatedNvmeHostKeyReplaceSession ||
          repository is! AuthenticatedNvmeHostChoicesSession ||
          repository is! AuthenticatedNvmeHostAuthenticationClearSession) {
        return null;
      }
      final coordinator = NvmeHostKeyReplaceCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        replaceApi: repository as AuthenticatedNvmeHostKeyReplaceSession,
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

enum NvmeHostKeyReplaceOutcome { completed, rejected, unknown }

final class NvmeHostKeyReplaceResult {
  const NvmeHostKeyReplaceResult(this.outcome, this.message);
  final NvmeHostKeyReplaceOutcome outcome;
  final String message;
}

final class NvmeHostKeyReplaceReview {
  NvmeHostKeyReplaceReview._(
    this.endpoint,
    this.hash,
    this.group,
    this._keys,
    this._credentialReview,
    this.proof,
    this.issuedAt,
  ) : hasControllerKey = _keys.hasControllerKey;
  final String endpoint, hash, proof;
  final String? group;
  final bool hasControllerKey;
  final DateTime issuedAt;
  final NvmeHostKeyDraft _keys;
  final NvmeHostKeyReplacementReview _credentialReview;
  NvmeHostAuthentication get previous => _credentialReview.target;
  int get id => previous.id;
  String get nqn => previous.nqn;
  bool get hasKeys => !_keys.isDisposed && !_credentialReview.isDisposed;
  String get confirmation => 'REPLACE NVME HOST $id KEYS';
  void _dispose() {
    _keys.dispose();
    _credentialReview.dispose();
  }
}

/// Owns drafts from prepare through terminal execution or cancellation.
/// No subsystem association is created. Sequential checks cannot exclude other
/// administrators or attest key validity, runtime authentication or access.
final class NvmeHostKeyReplaceCoordinator {
  NvmeHostKeyReplaceCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.replaceApi,
    required this.choicesApi,
    required this.targetApi,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final AuthenticatedNvmeHostKeyReplaceSession replaceApi;
  final AuthenticatedNvmeHostChoicesSession choicesApi;
  final AuthenticatedNvmeHostAuthenticationClearSession targetApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmeHostKeyReplaceReview>{};
  NvmeHostKeyDraft? _active;
  NvmeHostKeyReplacementReview? _activeCredentialReview;
  bool _busy = false, _closed = false;
  bool get locked => _busy || _closed || NvmeWriteFence.isUncertain(session);
  bool get available =>
      !_closed &&
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('nvmet.host.update') != null &&
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
      review._dispose();
    }
    _issued.clear();
  }

  void dispose() {
    _closed = true;
    _cancelAll();
    _active?.dispose();
    _activeCredentialReview?.dispose();
  }

  void cancel(NvmeHostKeyReplaceReview review) {
    if (_issued.remove(review)) review._dispose();
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

  void _validate(NvmeMutationSnapshot value, int id, {String? nqn}) {
    final matches = value.hosts.hosts.where((h) => h.id == id).toList();
    if (matches.length != 1 ||
        (nqn != null && matches.single.nqn != nqn) ||
        value.hosts.mappings.any((m) => m.hostId == id)) {
      throw StateError(
        'Select an existing unassociated host. Nothing was sent.',
      );
    }
  }

  bool _validTime(NvmeHostKeyReplaceReview review) {
    final now = _now().toUtc();
    return [review.issuedAt, review._credentialReview.issuedAt].every(
      (issued) =>
          !now.isBefore(issued) &&
          now.difference(issued) < const Duration(minutes: 5),
    );
  }

  Future<NvmeHostKeyReplaceReview> prepare(
    int id, {
    required String hash,
    required String? group,
    required NvmeHostKeyDraft keys,
  }) async {
    if (identical(keys, _active) ||
        _issued.any((r) => identical(r._keys, keys))) {
      throw StateError(
        'Imported keys already belong to another review or operation.',
      );
    }
    var retained = false;
    Object? owner;
    NvmeHostKeyReplacementReview? credentialReview;
    try {
      _guard();
      if (!available ||
          _busy ||
          id <= 0 ||
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
          'Enter an exact host ID, supported algorithms and imported keys. Nothing was sent.',
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
      final before = await _snapshot();
      _validate(before, id);
      try {
        credentialReview = await replaceApi.reviewNvmeHostKeyReplacement(id);
      } on Object {
        throw StateError(
          'Protected credential review failed. Nothing was sent.',
        );
      }
      _activeCredentialReview = credentialReview;
      _guard();
      if (credentialReview.isDisposed ||
          credentialReview.target.id != id ||
          credentialReview.target.inconsistent) {
        throw StateError('Protected target is invalid. Nothing was sent.');
      }
      final after = await _snapshot();
      _validate(after, id, nqn: credentialReview.target.nqn);
      if (after.proof() != before.proof() || keys.isDisposed) {
        throw StateError(
          'NVMe configuration changed during review. Nothing was sent.',
        );
      }
      final review = NvmeHostKeyReplaceReview._(
        session.endpoint!,
        hash,
        group,
        keys,
        credentialReview,
        after.proof(),
        _now().toUtc(),
      );
      if (!_validTime(review)) {
        throw StateError(
          'Protected credential review expired. Nothing was sent.',
        );
      }
      _issued.add(review);
      retained = true;
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe key replacement preflight failed. Nothing was sent.',
      );
    } finally {
      if (!retained) {
        keys.dispose();
        credentialReview?.dispose();
      }
      if (owner != null) {
        _active = null;
        _activeCredentialReview = null;
        _busy = false;
        lock.release(owner);
      }
    }
  }

  Future<NvmeHostKeyReplaceResult> execute(
    NvmeHostKeyReplaceReview review,
    String phrase, {
    bool acknowledgeKeyLimitations = false,
    bool acknowledgeNoAssociation = false,
    bool acknowledgeCredentialLoss = false,
  }) async {
    if (!_issued.remove(review)) {
      return const NvmeHostKeyReplaceResult(
        NvmeHostKeyReplaceOutcome.rejected,
        'Review is invalid. Nothing was sent.',
      );
    }
    Object? owner;
    var sent = false;
    try {
      if (_busy ||
          !available ||
          !isCurrent() ||
          NvmeWriteFence.isUncertain(session) ||
          !review.hasKeys ||
          !_validTime(review) ||
          review.endpoint != session.endpoint ||
          phrase != review.confirmation ||
          !acknowledgeKeyLimitations ||
          !acknowledgeNoAssociation ||
          !acknowledgeCredentialLoss) {
        return const NvmeHostKeyReplaceResult(
          NvmeHostKeyReplaceOutcome.rejected,
          'Review, consent or confirmation is invalid. Nothing was sent.',
        );
      }
      owner = lock.acquire();
      if (owner == null) {
        return const NvmeHostKeyReplaceResult(
          NvmeHostKeyReplaceOutcome.rejected,
          'Another server operation is in progress. Nothing was sent.',
        );
      }
      _busy = true;
      _active = review._keys;
      _activeCredentialReview = review._credentialReview;
      await _choices(review.hash, review.group);
      final before = await _snapshot();
      _validate(before, review.id, nqn: review.nqn);
      final target = await targetApi.loadNvmeHostAuthenticationTarget(
        review.id,
      );
      _guard();
      if (before.proof() != review.proof ||
          !target.sameReturnedSettings(review.previous) ||
          !review.hasKeys ||
          !_validTime(review)) {
        return const NvmeHostKeyReplaceResult(
          NvmeHostKeyReplaceOutcome.rejected,
          'Configuration changed or review expired. Nothing was sent.',
        );
      }
      // Entering the SDK is conservatively treated as possible dispatch. Its private
      // credential proof detects returned key rotations even with unchanged flags.
      sent = true;
      final changed = await replaceApi.replaceNvmeHostImportedKeys(
        review: review._credentialReview,
        hash: review.hash,
        group: review.group,
        keys: review._keys,
      );
      _guard();
      if (changed.id != review.id ||
          changed.nqn != review.nqn ||
          changed.hash != review.hash ||
          changed.group != review.group ||
          !changed.hostKeyReturned ||
          changed.controllerKeyReturned != review.hasControllerKey) {
        return _unknown();
      }
      final after = await _snapshot();
      _validate(after, review.id, nqn: review.nqn);
      final confirmed = await targetApi.loadNvmeHostAuthenticationTarget(
        review.id,
      );
      _guard();
      if (!confirmed.sameReturnedSettings(changed) ||
          after.proof() != before.proof()) {
        return _unknown();
      }
      return NvmeHostKeyReplaceResult(
        NvmeHostKeyReplaceOutcome.completed,
        'Host #${review.id} was found with reviewed public authentication settings, unchanged NQN and public topology, and no subsystem mapping. The SDK privately checked exact saved keys. Key validity, compatibility, runtime authentication and access were not verified.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostKeyReplaceResult(
              NvmeHostKeyReplaceOutcome.rejected,
              'NVMe key replacement preflight failed. Nothing was sent.',
            );
    } finally {
      review._dispose();
      if (owner != null) {
        _active = null;
        _activeCredentialReview = null;
        _busy = false;
        lock.release(owner);
      }
    }
  }

  NvmeHostKeyReplaceResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _cancelAll();
    return const NvmeHostKeyReplaceResult(
      NvmeHostKeyReplaceOutcome.unknown,
      'Key replacement may have changed the server. Do not retry; inspect the original server and reconnect. Old keys cannot be restored by the app.',
    );
  }
}
