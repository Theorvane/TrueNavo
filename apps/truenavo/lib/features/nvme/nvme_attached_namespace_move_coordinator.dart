import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeAttachedNamespaceMoveCoordinatorProvider =
    Provider.autoDispose<NvmeAttachedNamespaceMoveCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeAttachedNamespaceMoveCoordinator(
        session: session!,
        api: api as AuthenticatedAdminSession,
        hostsApi: api as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            ref.mounted &&
            identical(session, ref.read(dashboardActiveSessionProvider)),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

enum NvmeAttachedNamespaceMoveOutcome { completed, rejected, unknown }

final nvmePairedNamespaceMoveCoordinatorProvider =
    Provider.autoDispose<NvmeAttachedNamespaceMoveCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeAttachedNamespaceMoveCoordinator(
        session: session!,
        api: api as AuthenticatedAdminSession,
        hostsApi: api as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        requireAttachedDestination: true,
        isCurrent: () =>
            ref.mounted &&
            identical(session, ref.read(dashboardActiveSessionProvider)),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

final class NvmeAttachedNamespaceMoveResult {
  const NvmeAttachedNamespaceMoveResult(this.outcome, this.message);
  final NvmeAttachedNamespaceMoveOutcome outcome;
  final String message;
}

final nvmeIsolatedSourceAttachedDestinationMoveCoordinatorProvider =
    Provider.autoDispose<NvmeAttachedNamespaceMoveCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeAttachedNamespaceMoveCoordinator(
        session: session!,
        api: api as AuthenticatedAdminSession,
        hostsApi: api as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        requireAttachedDestination: true,
        requireIsolatedSource: true,
        isCurrent: () =>
            ref.mounted &&
            identical(session, ref.read(dashboardActiveSessionProvider)),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

final class NvmeAttachedNamespaceMoveReview {
  NvmeAttachedNamespaceMoveReview._(
    this.endpoint,
    this.target,
    this.source,
    this.destination,
    this.destinationNamespaces,
    this.sourceNamespaces,
    this.mapping,
    this.port,
    this.destinationMapping,
    this.destinationPort,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeNamespace target;
  final NvmeSubsystem source, destination;
  final List<NvmeNamespace> destinationNamespaces, sourceNamespaces;
  final NvmePortMapping? mapping;
  final NvmePort? port;
  final NvmePortMapping? destinationMapping;
  final NvmePort? destinationPort;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'MOVE ${mapping == null ? 'ISOLATED' : 'ATTACHED'} NVME NAMESPACE ${target.id} FROM SUBSYSTEM ${source.id} NQN ${source.subnqn} TO ${destination.id} NQN ${destination.subnqn} KEEP NSID ${target.nsid}'
      '${mapping == null ? '' : ' KEEP ASSOCIATION ${mapping!.id} PORT ${port!.id}'}'
      '${destinationMapping == null ? '' : ' KEEP DESTINATION ASSOCIATION ${destinationMapping!.id} PORT ${destinationPort!.id}'}';
}

/// A public discovery hint, never authority to dispatch a change.
final class NvmeAttachedNamespaceMoveCandidate {
  NvmeAttachedNamespaceMoveCandidate._(
    this.target,
    this.source,
    Iterable<NvmeSubsystem> destinations,
  ) : destinations = List.unmodifiable(destinations);
  final NvmeNamespace target;
  final NvmeSubsystem source;
  final List<NvmeSubsystem> destinations;
}

/// Saved subsystem assignment only; no backing paths, sizes or identifiers are submitted.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeAttachedNamespaceMoveCoordinator {
  NvmeAttachedNamespaceMoveCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.lock,
    required this.isCurrent,
    this.requireAttachedDestination = false,
    this.requireIsolatedSource = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final bool requireAttachedDestination;
  final bool requireIsolatedSource;
  final DateTime Function() _now;
  final _issued = <NvmeAttachedNamespaceMoveReview>{};
  bool _busy = false, _closed = false;
  bool get locked => _busy || _closed || NvmeWriteFence.isUncertain(session);
  bool get available =>
      !_closed &&
      (!requireIsolatedSource || requireAttachedDestination) &&
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('nvmet.host.query') != null &&
      [
        'nvmet.host_subsys.query',
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.namespace.update',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void dispose() {
    _closed = true;
    _issued.clear();
  }

  void cancel(NvmeAttachedNamespaceMoveReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Attached namespace move review is unavailable.');
    }
  }

  bool _fresh(NvmeAttachedNamespaceMoveReview review) {
    final age = _now().toUtc().difference(review.issuedAt);
    return !age.isNegative && age < const Duration(minutes: 5);
  }

  Future<NvmeMutationSnapshot> _snapshot() async {
    final value = await NvmeMutationSnapshot.load(
      api: api,
      hostsApi: hostsApi,
      isCurrent: () => !_closed && isCurrent(),
    );
    _guard();
    return value;
  }

  NvmeSubsystem _source(NvmeMutationSnapshot snapshot, int id) {
    return _restricted(snapshot, id, attached: !requireIsolatedSource);
  }

  NvmeSubsystem _restricted(
    NvmeMutationSnapshot snapshot,
    int id, {
    bool attached = true,
  }) {
    final source = snapshot.topology.subsystems
        .where((s) => s.id == id)
        .singleOrNull;
    final nqns = snapshot.topology.subsystems.map((s) => s.subnqn).toList();
    final mappings = snapshot.topology.portMappings
        .where((m) => m.subsystemId == id)
        .toList();
    final port = mappings.length == 1
        ? snapshot.topology.ports
              .where((p) => p.id == mappings.single.portId)
              .singleOrNull
        : null;
    final residents = snapshot.topology.namespaces
        .where((n) => n.subsystemId == id)
        .toList();
    final nsids = residents.map((n) => n.nsid).toList();
    if (source == null ||
        source.allowAnyHost ||
        source.subnqn == null ||
        nqns.any((n) => n == null) ||
        nqns.toSet().length != nqns.length ||
        (attached
            ? (mappings.length != 1 ||
                  port == null ||
                  port.enabled ||
                  !const {'TCP', 'RDMA'}.contains(port.transport) ||
                  snapshot.topology.portMappings
                          .where((m) => m.portId == port.id)
                          .length !=
                      1)
            : mappings.isNotEmpty) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == id) ||
        residents.any(
          (n) => n.deviceType != 'ZVOL' || n.enabled || n.locked != false,
        ) ||
        nsids.any((n) => n == null || n <= 0 || n >= 4294967295) ||
        nsids.toSet().length != nsids.length) {
      throw StateError(
        'Select a restricted source with one disabled unshared TCP/RDMA association, no host grant, known unique public NQNs and only disabled unlocked unique-NSID ZVOL residents.',
      );
    }
    return source;
  }

  NvmeNamespace _target(NvmeMutationSnapshot snapshot, int id) {
    final target = snapshot.topology.namespaces
        .where((n) => n.id == id)
        .singleOrNull;
    if (target == null ||
        target.deviceType != 'ZVOL' ||
        target.enabled ||
        target.locked != false ||
        target.nsid == null ||
        target.nsid! <= 0 ||
        target.nsid! >= 4294967295) {
      throw StateError(
        'Only singly attached disabled unlocked ZVOL namespaces with a valid NSID are supported.',
      );
    }
    _source(snapshot, target.subsystemId);
    return target;
  }

  NvmeSubsystem _destination(
    NvmeMutationSnapshot snapshot,
    int sourceId,
    int destinationId, {
    required int preservedNsid,
    int? movedId,
  }) {
    final source = _source(snapshot, sourceId);
    final destination = snapshot.topology.subsystems
        .where((s) => s.id == destinationId)
        .singleOrNull;
    if (destination == null ||
        sourceId == destinationId ||
        source.subnqn == null ||
        destination.subnqn == null ||
        source.subnqn == destination.subnqn ||
        source.allowAnyHost ||
        destination.allowAnyHost ||
        (!requireAttachedDestination &&
            snapshot.topology.portMappings.any(
              (m) => m.subsystemId == destinationId,
            )) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == destinationId)) {
      throw StateError(
        'Select a different restricted destination compatible with the selected mode and a known distinct NQN.',
      );
    }
    if (requireAttachedDestination) _restricted(snapshot, destinationId);
    final namespaces = snapshot.topology.namespaces
        .where((n) => n.subsystemId == destinationId && n.id != movedId)
        .toList();
    final nsids = namespaces.map((n) => n.nsid).toList();
    if (namespaces.any(
          (n) => n.deviceType != 'ZVOL' || n.enabled || n.locked != false,
        ) ||
        nsids.any(
          (id) =>
              id == null || id <= 0 || id >= 4294967295 || id == preservedNsid,
        ) ||
        nsids.toSet().length != nsids.length) {
      throw StateError(
        'Destination namespaces must be disabled unlocked ZVOLs with known unique noncolliding NSIDs.',
      );
    }
    return destination;
  }

  /// Loads only public metadata. Selection still requires an independent review.
  Future<List<NvmeAttachedNamespaceMoveCandidate>> loadCandidates() async {
    _guard();
    if (_busy) throw StateError('Another operation is in progress.');
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final result = <NvmeAttachedNamespaceMoveCandidate>[];
      for (final namespace in snapshot.topology.namespaces) {
        final NvmeNamespace target;
        try {
          target = _target(snapshot, namespace.id);
        } on StateError {
          continue;
        }
        final destinations = <NvmeSubsystem>[];
        for (final subsystem in snapshot.topology.subsystems) {
          try {
            destinations.add(
              _destination(
                snapshot,
                target.subsystemId,
                subsystem.id,
                preservedNsid: target.nsid!,
              ),
            );
          } on StateError {
            continue;
          }
        }
        destinations.sort((a, b) => a.id.compareTo(b.id));
        if (destinations.isNotEmpty) {
          result.add(
            NvmeAttachedNamespaceMoveCandidate._(
              target,
              snapshot.topology.subsystems.singleWhere(
                (s) => s.id == target.subsystemId,
              ),
              destinations,
            ),
          );
        }
      }
      result.sort((a, b) => a.target.id.compareTo(b.target.id));
      _guard();
      return List.unmodifiable(result);
    } on Object {
      throw StateError(
        'Move target discovery failed. No configuration request was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeAttachedNamespaceMoveReview> prepare(
    int id, {
    required int destinationId,
  }) async {
    _guard();
    if (_busy || id <= 0 || destinationId <= 0) {
      throw StateError('Select an exact namespace database ID.');
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _target(snapshot, id);
      final destination = _destination(
        snapshot,
        target.subsystemId,
        destinationId,
        preservedNsid: target.nsid!,
      );
      final source = snapshot.topology.subsystems.singleWhere(
        (s) => s.id == target.subsystemId,
      );
      final review = NvmeAttachedNamespaceMoveReview._(
        session.endpoint!,
        target,
        source,
        destination,
        List.unmodifiable(
          snapshot.topology.namespaces
              .where((n) => n.subsystemId == destinationId)
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id)),
        ),
        List.unmodifiable(
          snapshot.topology.namespaces
              .where(
                (n) => n.subsystemId == target.subsystemId && n.id != target.id,
              )
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id)),
        ),
        requireIsolatedSource
            ? null
            : snapshot.topology.portMappings
                  .where((m) => m.subsystemId == source.id)
                  .single,
        requireIsolatedSource
            ? null
            : snapshot.topology.ports
                  .where(
                    (p) =>
                        p.id ==
                        snapshot.topology.portMappings
                            .where((m) => m.subsystemId == source.id)
                            .single
                            .portId,
                  )
                  .single,
        requireAttachedDestination
            ? snapshot.topology.portMappings.singleWhere(
                (m) => m.subsystemId == destinationId,
              )
            : null,
        requireAttachedDestination
            ? snapshot.topology.ports.singleWhere(
                (p) =>
                    p.id ==
                    snapshot.topology.portMappings
                        .singleWhere((m) => m.subsystemId == destinationId)
                        .portId,
              )
            : null,
        snapshot.proof(),
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on Object {
      throw StateError(
        'Attached namespace move preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeAttachedNamespaceMoveResult> execute(
    NvmeAttachedNamespaceMoveReview review,
    String phrase, {
    required bool acknowledgeReload,
    required bool acknowledgeLimitations,
    required bool acknowledgeIdentityRisk,
    bool acknowledgeDestinationExposure = false,
  }) async {
    final issued = _issued.remove(review);
    if (!issued ||
        locked ||
        !available ||
        !isCurrent() ||
        !_fresh(review) ||
        review.endpoint != session.endpoint ||
        phrase != review.confirmation ||
        !acknowledgeReload ||
        !acknowledgeLimitations ||
        !acknowledgeIdentityRisk ||
        (review.destinationMapping != null &&
            !acknowledgeDestinationExposure)) {
      return _rejected();
    }
    final owner = lock.acquire();
    if (owner == null) return _rejected();
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final target = _target(before, review.target.id);
      if (before.proof() != review._proof ||
          target.subsystemId == review.destination.id ||
          !_fresh(review)) {
        return _rejected();
      }
      _destination(
        before,
        target.subsystemId,
        review.destination.id,
        preservedNsid: target.nsid!,
      );
      _guard();
      final method = api.adminCatalog.method('nvmet.namespace.update');
      if (method == null || !method.supported) return _rejected();
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            target.id,
            {'subsys_id': review.destination.id},
          ],
        ),
      );
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = NvmeNamespace.parse(response.value as Map);
      bool matches(NvmeNamespace? n) =>
          n != null &&
          n.id == target.id &&
          n.subsystemId == review.destination.id &&
          n.nsid == target.nsid &&
          n.deviceType == target.deviceType &&
          n.locked == false &&
          n.enabled == false;
      if (!matches(returned)) return _unknown();
      final after = await _snapshot();
      if (!matches(
            after.topology.namespaces
                .where((n) => n.id == target.id)
                .singleOrNull,
          ) ||
          before.topology.namespaces.length !=
              after.topology.namespaces.length ||
          before.proof(omitNamespaceId: target.id) !=
              after.proof(omitNamespaceId: target.id)) {
        return _unknown();
      }
      _destination(
        after,
        target.subsystemId,
        review.destination.id,
        preservedNsid: target.nsid!,
        movedId: target.id,
      );
      return NvmeAttachedNamespaceMoveResult(
        NvmeAttachedNamespaceMoveOutcome.completed,
        'Namespace #${target.id} saved subsystem #${review.destination.id} and unchanged NSID=${target.nsid} verified in a fresh public read. No backing fields were submitted; backing identity, health and runtime access were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeAttachedNamespaceMoveResult _rejected() =>
      const NvmeAttachedNamespaceMoveResult(
        NvmeAttachedNamespaceMoveOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeAttachedNamespaceMoveResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeAttachedNamespaceMoveResult(
      NvmeAttachedNamespaceMoveOutcome.unknown,
      'Attached namespace move may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
