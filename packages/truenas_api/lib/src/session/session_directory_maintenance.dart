part of 'true_nas_session_repository.dart';

typedef _DirectoryMaintenanceSnapshot = ({
  DirectoryIdmapInventory inventory,
  String proof,
});

extension _DirectoryMaintenance on _SessionDirectoryIdmap {
  bool _available(DirectoryMaintenanceAction action) =>
      action == DirectoryMaintenanceAction.refreshCache
      ? capabilities.canRefreshCache
      : capabilities.canSyncKeytab;

  Future<Object?> _maintenanceCall(
    DirectoryMaintenanceAction action,
    String method,
    List<Object?> params,
  ) async {
    if (_disposed || !isCurrent() || !_available(action)) {
      throw const DirectoryIdmapException();
    }
    final result = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    if (_disposed || !isCurrent()) throw const DirectoryIdmapException();
    return result;
  }

  Future<_DirectoryMaintenanceSnapshot> _maintenanceSnapshot(
    DirectoryMaintenanceAction action,
  ) async {
    if (!_available(action)) throw const DirectoryIdmapException();
    final inventory = await load();
    final beforeAdmin = _configurationBackupAdmin(
      await _maintenanceCall(action, 'auth.me', const []),
    );
    final ha = await _maintenanceCall(action, 'failover.licensed', const []);
    final state = await _maintenanceCall(action, 'system.state', const []);
    final beforeHost = await _maintenanceCall(
      action,
      'system.host_id',
      const [],
    );
    final raw = await _maintenanceCall(
      action,
      'directoryservices.config',
      const [],
    );
    final status = await _maintenanceCall(
      action,
      'directoryservices.status',
      const [],
    );
    final afterHost = await _maintenanceCall(
      action,
      'system.host_id',
      const [],
    );
    final afterAdmin = _configurationBackupAdmin(
      await _maintenanceCall(action, 'auth.me', const []),
    );
    if (!beforeAdmin ||
        !afterAdmin ||
        ha != false ||
        state != 'READY' ||
        beforeHost != inventory.hostId ||
        afterHost != inventory.hostId ||
        !inventory.enabled ||
        inventory.status != 'HEALTHY' ||
        !{'ACTIVEDIRECTORY', 'LDAP', 'IPA'}.contains(inventory.serviceType) ||
        action == DirectoryMaintenanceAction.syncKeytab &&
            inventory.serviceType != 'ACTIVEDIRECTORY' ||
        raw is! Map ||
        !_smbBounded(raw) ||
        raw['enable'] != true ||
        raw['service_type'] != inventory.serviceType ||
        status is! Map ||
        status['type'] != inventory.serviceType ||
        status['status'] != 'HEALTHY') {
      throw const DirectoryIdmapException();
    }
    return (inventory: inventory, proof: _digest(raw));
  }

  Future<DirectoryMaintenanceReview> reviewCacheRefresh() =>
      _reviewMaintenance(DirectoryMaintenanceAction.refreshCache);

  Future<DirectoryMaintenanceReview> reviewKeytabSync() =>
      _reviewMaintenance(DirectoryMaintenanceAction.syncKeytab);

  Future<DirectoryMaintenanceReview> _reviewMaintenance(
    DirectoryMaintenanceAction action,
  ) async {
    if (_busy || _uncertain || _disposed || isOtherMutationBusy()) {
      throw const DirectoryIdmapException();
    }
    final snapshot = await _maintenanceSnapshot(action);
    final review = DirectoryMaintenanceReview._(
      action,
      snapshot.inventory,
      action == DirectoryMaintenanceAction.refreshCache
          ? 'REFRESH ${snapshot.inventory.serviceType} CACHE ${snapshot.inventory.hostId.substring(0, 8)}'
          : 'SYNC AD KEYTAB ${snapshot.inventory.hostId.substring(0, 8)}',
      DateTime.now().toUtc().add(const Duration(minutes: 2)),
      snapshot.proof,
    );
    _review = null;
    _ldapReview = null;
    _activationReview = null;
    _maintenanceReview = review;
    return review;
  }

  DirectoryMaintenanceResult _maintenanceUnknown(DirectoryMaintenanceJob? job) {
    _busy = true;
    _uncertain = true;
    _maintenanceReview = null;
    return DirectoryMaintenanceResult(
      DirectoryIdmapOutcome.unknown,
      job == null
          ? 'Directory operation may have started. Inspect the original server job; do not resubmit.'
          : 'The owned directory job could not be verified. Inspect the original server.',
      job: job,
    );
  }

  Future<DirectoryMaintenanceResult> executeCacheRefresh(
    DirectoryMaintenanceReview review,
    String confirmation,
  ) => _executeMaintenance(
    DirectoryMaintenanceAction.refreshCache,
    review,
    confirmation,
  );

  Future<DirectoryMaintenanceResult> executeKeytabSync(
    DirectoryMaintenanceReview review,
    String confirmation,
  ) => _executeMaintenance(
    DirectoryMaintenanceAction.syncKeytab,
    review,
    confirmation,
  );

  Future<DirectoryMaintenanceResult> _executeMaintenance(
    DirectoryMaintenanceAction action,
    DirectoryMaintenanceReview review,
    String confirmation,
  ) async {
    if (_maintenanceReview != review ||
        review.action != action ||
        _busy ||
        _uncertain ||
        _disposed ||
        isOtherMutationBusy() ||
        DateTime.now().toUtc().isAfter(review.expiresAt) ||
        confirmation != review.confirmation) {
      throw const DirectoryIdmapException();
    }
    _maintenanceReview = null;
    _busy = true;
    var sent = false;
    try {
      final fresh = await _maintenanceSnapshot(action);
      if (fresh.proof != review._proof ||
          fresh.inventory.endpoint != review.inventory.endpoint ||
          fresh.inventory.hostId != review.inventory.hostId ||
          fresh.inventory.serviceType != review.inventory.serviceType) {
        throw const DirectoryIdmapException();
      }
      sent = true;
      final receipt = await _maintenanceCall(action, action.method, const []);
      if (receipt is! int || receipt <= 0) return _maintenanceUnknown(null);
      final job = DirectoryMaintenanceJob._(
        action,
        receipt,
        fresh.inventory.endpoint,
        fresh.inventory.hostId,
        fresh.proof,
      );
      _maintenanceJob = job;
      return DirectoryMaintenanceResult(
        DirectoryIdmapOutcome.pending,
        'The directory operation was submitted once. Check its owned job.',
        job: job,
      );
    } on Object {
      if (sent) return _maintenanceUnknown(null);
      _busy = false;
      return const DirectoryMaintenanceResult(
        DirectoryIdmapOutcome.rejected,
        'Preflight changed; no directory operation was submitted.',
      );
    }
  }

  Future<DirectoryMaintenanceResult> pollCacheRefresh(
    DirectoryMaintenanceJob job,
  ) => _pollMaintenance(DirectoryMaintenanceAction.refreshCache, job);

  Future<DirectoryMaintenanceResult> pollKeytabSync(
    DirectoryMaintenanceJob job,
  ) => _pollMaintenance(DirectoryMaintenanceAction.syncKeytab, job);

  Future<DirectoryMaintenanceResult> _pollMaintenance(
    DirectoryMaintenanceAction action,
    DirectoryMaintenanceJob job,
  ) async {
    if (_maintenanceJob != job ||
        job.action != action ||
        job.endpoint != _endpoint ||
        _disposed ||
        !isCurrent() ||
        !_available(action)) {
      throw const DirectoryIdmapException();
    }
    try {
      final raw = await _maintenanceCall(action, 'core.get_jobs', [
        [
          ['id', '=', job.id],
        ],
        {
          'limit': 2,
          'select': ['id', 'method', 'arguments', 'state'],
        },
      ]);
      if (raw is! List || raw.length != 1 || raw.single is! Map) {
        return _maintenanceUnknown(job);
      }
      final row = raw.single as Map;
      if (row['id'] != job.id ||
          row['method'] != action.method ||
          row['arguments'] is! List ||
          (row['arguments'] as List).isNotEmpty) {
        return _maintenanceUnknown(job);
      }
      if (row['state'] == 'WAITING' || row['state'] == 'RUNNING') {
        return DirectoryMaintenanceResult(
          DirectoryIdmapOutcome.pending,
          'The owned directory job is still running.',
          job: job,
        );
      }
      if (row['state'] == 'SUCCESS' ||
          row['state'] == 'FAILED' ||
          row['state'] == 'ABORTED') {
        final saved = await _maintenanceSnapshot(action);
        if (saved.inventory.hostId != job.hostId ||
            saved.inventory.endpoint != job.endpoint ||
            saved.proof != job._proof) {
          return _maintenanceUnknown(job);
        }
        _busy = false;
        _uncertain = false;
        _maintenanceJob = null;
        return row['state'] == 'SUCCESS'
            ? const DirectoryMaintenanceResult(
                DirectoryIdmapOutcome.completed,
                'The owned directory job succeeded.',
              )
            : const DirectoryMaintenanceResult(
                DirectoryIdmapOutcome.rejected,
                'The owned directory job did not succeed; configuration is unchanged.',
              );
      }
      return _maintenanceUnknown(job);
    } on Object {
      return _maintenanceUnknown(job);
    }
  }
}
