part of 'true_nas_session_repository.dart';

final class DirectoryLdapActivationReview {
  const DirectoryLdapActivationReview._(
    this.enable,
    this.inventory,
    this.confirmation,
    this.expiresAt,
    this._proof,
  );
  final bool enable;
  final DirectoryIdmapInventory inventory;
  final String confirmation;
  final DateTime expiresAt;
  final String _proof;
}

final class DirectoryLdapActivationJob {
  const DirectoryLdapActivationJob._(
    this.id,
    this.enable,
    this.endpoint,
    this.hostId,
    this.payloadProof,
    this._beforeProof,
    this._beforeStatus,
    this._expectedConfiguration,
  );
  final int id;
  final bool enable;
  final String endpoint, hostId, payloadProof, _beforeProof;
  final String? _beforeStatus;
  final Map<String, Object?> _expectedConfiguration;
}

final class DirectoryLdapActivationResult {
  const DirectoryLdapActivationResult(this.outcome, this.message, {this.job});
  final DirectoryIdmapOutcome outcome;
  final String message;
  final DirectoryLdapActivationJob? job;
}

extension _DirectoryLdapActivationWriter on _SessionDirectoryIdmap {
  Future<DirectoryLdapActivationReview> reviewLdapActivation(
    bool enable,
  ) async {
    if (_busy || _uncertain || _disposed || isOtherMutationBusy()) {
      throw const DirectoryIdmapException();
    }
    final snapshot = await _ldapSnapshot(allowEnabled: true);
    if (snapshot.inventory.enabled == enable) {
      throw const DirectoryIdmapException();
    }
    if (enable) {
      final ldap = snapshot.inventory.ldap!;
      final allLdaps = ldap.serverUrls.every(
        (url) => url.startsWith('ldaps://'),
      );
      final allStartTls =
          ldap.serverUrls.every((url) => url.startsWith('ldap://')) &&
          ldap.startTls;
      if (!ldap.validateCertificates ||
          !(allLdaps && !ldap.startTls || allStartTls)) {
        throw const DirectoryIdmapException();
      }
    }
    final review = DirectoryLdapActivationReview._(
      enable,
      snapshot.inventory,
      '${enable ? 'ENABLE' : 'DISABLE'} LDAP ${snapshot.inventory.hostId.substring(0, 8)}',
      DateTime.now().toUtc().add(const Duration(minutes: 2)),
      snapshot.proof,
    );
    _review = null;
    _maintenanceReview = null;
    _ldapReview = null;
    _activationReview = review;
    return review;
  }

  DirectoryLdapActivationResult _activationUnknown(
    DirectoryLdapActivationJob? job,
  ) {
    _busy = true;
    _uncertain = true;
    _activationReview = null;
    return DirectoryLdapActivationResult(
      DirectoryIdmapOutcome.unknown,
      job == null
          ? 'Directory service state may have changed. Inspect the original server; do not repeat the request.'
          : 'The owned LDAP activation job or saved state could not be verified.',
      job: job,
    );
  }

  Future<DirectoryLdapActivationResult> executeLdapActivation(
    DirectoryLdapActivationReview review,
    String confirmation,
  ) async {
    if (_activationReview != review ||
        _busy ||
        _uncertain ||
        _disposed ||
        isOtherMutationBusy() ||
        DateTime.now().toUtc().isAfter(review.expiresAt) ||
        confirmation != review.confirmation) {
      throw const DirectoryIdmapException();
    }
    _activationReview = null;
    _busy = true;
    var sent = false;
    try {
      final fresh = await _ldapSnapshot(allowEnabled: true);
      if (fresh.proof != review._proof ||
          fresh.inventory.endpoint != review.inventory.endpoint ||
          fresh.inventory.hostId != review.inventory.hostId ||
          fresh.inventory.status != review.inventory.status ||
          fresh.inventory.enabled == review.enable) {
        throw const DirectoryIdmapException();
      }
      final configuration = <String, Object?>{
        ...fresh.configuration,
        'service_type': 'LDAP',
      };
      final payload = <String, Object?>{
        'enable': review.enable,
        'service_type': 'LDAP',
        'credential': {'credential_type': 'LDAP_ANONYMOUS'},
        'configuration': configuration,
        ...fresh.common,
        'force': false,
      };
      final payloadProof = _digest(payload);
      sent = true;
      final receipt = await _writeCall('directoryservices.update', [payload]);
      if (receipt is! int || receipt <= 0) return _activationUnknown(null);
      final job = DirectoryLdapActivationJob._(
        receipt,
        review.enable,
        fresh.inventory.endpoint,
        fresh.inventory.hostId,
        payloadProof,
        fresh.proof,
        fresh.inventory.status,
        configuration,
      );
      _activationJob = job;
      return DirectoryLdapActivationResult(
        DirectoryIdmapOutcome.pending,
        'The LDAP state change was submitted once. Check its owned job.',
        job: job,
      );
    } on Object {
      if (sent) return _activationUnknown(null);
      _busy = false;
      return const DirectoryLdapActivationResult(
        DirectoryIdmapOutcome.rejected,
        'Preflight changed; no LDAP state change was submitted.',
      );
    }
  }

  Future<DirectoryLdapActivationResult> pollLdapActivation(
    DirectoryLdapActivationJob job,
  ) async {
    if (_activationJob != job ||
        job.endpoint != _endpoint ||
        _disposed ||
        !isCurrent() ||
        !capabilities.canEdit) {
      throw const DirectoryIdmapException();
    }
    try {
      final rows = await _writeCall('core.get_jobs', [
        [
          ['id', '=', job.id],
        ],
        {
          'limit': 2,
          'select': ['id', 'method', 'arguments', 'state'],
        },
      ]);
      if (rows is! List || rows.length != 1 || rows.single is! Map) {
        return _activationUnknown(job);
      }
      final row = rows.single as Map;
      if (row['id'] != job.id ||
          row['method'] != 'directoryservices.update' ||
          row['arguments'] is! List ||
          (row['arguments'] as List).length != 1 ||
          _digest((row['arguments'] as List).single) != job.payloadProof) {
        return _activationUnknown(job);
      }
      if (row['state'] == 'WAITING' || row['state'] == 'RUNNING') {
        return DirectoryLdapActivationResult(
          DirectoryIdmapOutcome.pending,
          'The owned LDAP state-change job is still running.',
          job: job,
        );
      }
      if (row['state'] == 'SUCCESS' ||
          row['state'] == 'FAILED' ||
          row['state'] == 'ABORTED') {
        final saved = await _ldapSnapshot(allowEnabled: true);
        if (saved.inventory.endpoint != job.endpoint ||
            saved.inventory.hostId != job.hostId) {
          return _activationUnknown(job);
        }
        if (row['state'] == 'SUCCESS' &&
            (saved.inventory.enabled != job.enable ||
                saved.inventory.status !=
                    (job.enable ? 'HEALTHY' : 'DISABLED') ||
                _digest(saved.configuration) !=
                    _digest(job._expectedConfiguration))) {
          return _activationUnknown(job);
        }
        if (row['state'] != 'SUCCESS' &&
            (saved.proof != job._beforeProof ||
                saved.inventory.status != job._beforeStatus)) {
          return _activationUnknown(job);
        }
        _busy = false;
        _uncertain = false;
        _activationJob = null;
        return row['state'] == 'SUCCESS'
            ? const DirectoryLdapActivationResult(
                DirectoryIdmapOutcome.completed,
                'The owned LDAP job succeeded and saved service state was verified.',
              )
            : const DirectoryLdapActivationResult(
                DirectoryIdmapOutcome.rejected,
                'The owned LDAP job did not succeed; original state remains.',
              );
      }
      return _activationUnknown(job);
    } on Object {
      return _activationUnknown(job);
    }
  }
}
