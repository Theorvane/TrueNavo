part of 'true_nas_session_repository.dart';

/// Dedicated boot-environment reviews. Activation selects the next boot only.
abstract interface class AuthenticatedBootEnvironmentsSession {
  BootEnvironmentsCapabilities get bootEnvironmentsCapabilities;
  Future<BootEnvironmentInventory> loadBootEnvironments();
  Future<BootEnvironmentReview> reviewBootEnvironment(
    BootEnvironmentRequest request,
  );
  Future<BootEnvironmentResult> executeBootEnvironment(
    BootEnvironmentReview review,
  );
}

enum BootEnvironmentAction { clone, keep, activate, delete, rename }

final class BootEnvironmentsCapabilities {
  const BootEnvironmentsCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    this.actions = const {},
  });
  const BootEnvironmentsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      actions = const {};
  final bool connected;
  final bool versionSupported;
  final bool available;
  final Set<BootEnvironmentAction> actions;
  bool get supported => connected && versionSupported && available;
  bool supports(BootEnvironmentAction action) =>
      supported && actions.contains(action);
  String? get blockedReason => !connected
      ? 'Connect to a TrueNAS server first.'
      : !versionSupported
      ? 'Boot environments require a stable TrueNAS 25.10 release.'
      : !available
      ? 'The required boot-environment safety reads are unavailable to this account.'
      : null;
}

final class BootEnvironmentSnapshot {
  const BootEnvironmentSnapshot({
    required this.id,
    required this.dataset,
    required this.created,
    required this.usedBytes,
    required this.active,
    required this.activated,
    required this.keep,
    required this.canActivate,
  });
  final String id;
  final String dataset;

  /// Exact server creation value. The 25.10 service emits UTC without an offset.
  final String created;
  final int usedBytes;
  final bool active;
  final bool activated;
  final bool keep;
  final bool canActivate;
  bool get canClone => canActivate;
  bool get canActivateForNextBoot => canActivate && !activated;
  bool get canDelete => !active && !activated && !keep && canActivate;
}

final class BootEnvironmentInventory {
  BootEnvironmentInventory({
    required List<BootEnvironmentSnapshot> environments,
    required this.failoverLicensed,
    this.conflictingJob = false,
  }) : environments = List.unmodifiable(environments);
  final List<BootEnvironmentSnapshot> environments;
  final bool failoverLicensed;
  final bool conflictingJob;
  String? get blockedReason => failoverLicensed
      ? 'HA boot-environment changes require a coordinated failover workflow.'
      : conflictingJob
      ? 'A boot, update, or reboot operation is already running. Wait for it to finish.'
      : environments.isEmpty
      ? 'No boot environments were returned.'
      : null;
}

final class BootEnvironmentRequest {
  const BootEnvironmentRequest({
    required this.inventory,
    required this.snapshot,
    required this.action,
    this.targetName,
    this.keep,
  });
  final BootEnvironmentInventory inventory;
  final BootEnvironmentSnapshot snapshot;
  final BootEnvironmentAction action;
  final String? targetName;
  final bool? keep;
  String get label => switch (action) {
    BootEnvironmentAction.clone => 'Clone boot environment',
    BootEnvironmentAction.keep =>
      keep == true ? 'Keep boot environment' : 'Allow automatic cleanup',
    BootEnvironmentAction.activate => 'Use on next boot',
    BootEnvironmentAction.delete => 'Delete boot environment',
    BootEnvironmentAction.rename => 'Rename unavailable',
  };
  String? get validationError {
    if (action == BootEnvironmentAction.rename) {
      return 'TrueNAS 25.10 has no verified public boot-environment rename operation.';
    }
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (!inventory.environments.contains(snapshot)) {
      return 'Choose an environment from the current inventory.';
    }
    if (action != BootEnvironmentAction.clone && targetName != null ||
        action != BootEnvironmentAction.keep && keep != null) {
      return 'The request contains settings for a different operation.';
    }
    return switch (action) {
      BootEnvironmentAction.clone when !snapshot.canClone =>
        'This source has no supported boot kernel and cannot be cloned here.',
      BootEnvironmentAction.clone when !_bootNewName(targetName) => 'Use 1–64 letters, digits, periods, underscores or hyphens, starting with a letter or digit.',
      BootEnvironmentAction.clone
          when inventory.environments.any((e) => e.id == targetName) =>
        'A boot environment with this name already exists.',
      BootEnvironmentAction.keep when keep == null || keep == snapshot.keep =>
        'Choose a different automatic-cleanup setting.',
      BootEnvironmentAction.activate when !snapshot.canActivateForNextBoot => 'This environment is already selected for next boot or cannot be activated.',
      BootEnvironmentAction.delete when snapshot.active || snapshot.activated =>
        'The running and next-boot environments cannot be deleted.',
      BootEnvironmentAction.delete when snapshot.keep => 'Clear the keep protection in a separate reviewed action before deleting.',
      BootEnvironmentAction.delete when !snapshot.canActivate =>
        'Unsupported boot environments require the TrueNAS recovery workflow.',
      _ => null,
    };
  }
}

/// Only the authenticated adapter can issue a review. Construction is private.
final class BootEnvironmentReview {
  BootEnvironmentReview._(this.request);
  final BootEnvironmentRequest request;
}

enum BootEnvironmentOutcome { verified, rejected, unknown }

final class BootEnvironmentResult {
  const BootEnvironmentResult({required this.outcome, required this.message});
  final BootEnvironmentOutcome outcome;
  final String message;
}

enum BootEnvironmentsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  invalidResponse,
  staleReview,
  invalidRequest,
  unavailable,
}

final class BootEnvironmentsException implements Exception {
  const BootEnvironmentsException(this.reason);
  final BootEnvironmentsExceptionReason reason;
  String get userMessage => switch (reason) {
    BootEnvironmentsExceptionReason.notAuthenticated =>
      'Reconnect before managing boot environments.',
    BootEnvironmentsExceptionReason.unsupportedVersion =>
      'This boot-environment workflow requires stable TrueNAS 25.10.',
    BootEnvironmentsExceptionReason.unavailableMethod => 'The required public boot-environment methods are unavailable or unsupported.',
    BootEnvironmentsExceptionReason.busy => 'Another server operation or unresolved boot-environment change is in progress.',
    BootEnvironmentsExceptionReason.invalidResponse =>
      'Boot-environment identity or safety state could not be verified.',
    BootEnvironmentsExceptionReason.staleReview => 'The environment, inventory, or connection changed. Reload and review again.',
    BootEnvironmentsExceptionReason.invalidRequest =>
      'Review a supported boot-environment operation and exact target first.',
    BootEnvironmentsExceptionReason.unavailable => 'Boot-environment information is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _SessionBootEnvironments {
  _SessionBootEnvironments({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
  }) : _versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _methods = Set.unmodifiable(summary.availableMethodNames),
       _synchronousMethods = {
         if (metadata is Map)
           for (final entry in metadata.entries)
             if (entry.key is String &&
                 entry.value is Map &&
                 (entry.value as Map)['job'] == false &&
                 (entry.value as Map)['no_auth_required'] == false &&
                 (entry.value as Map)['uploadable'] == false &&
                 (entry.value as Map)['downloadable'] == false &&
                 (entry.value as Map)['private'] != true &&
                 (entry.value as Map)['_private'] != true)
               entry.key as String,
       };
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final bool Function() isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _versionSupported;
  final Set<String> _methods;
  final Set<String> _synchronousMethods;
  final Set<BootEnvironmentInventory> _inventories = {};
  final Map<BootEnvironmentReview, BootEnvironmentInventory> _reviews = {};
  bool _calling = false;
  bool _uncertain = false;
  bool get isBusy => _calling || _uncertain;
  static const _reads = {
    'boot.environment.query',
    'failover.licensed',
    'core.get_jobs',
  };
  BootEnvironmentsCapabilities get capabilities => BootEnvironmentsCapabilities(
    connected: isCurrent(),
    versionSupported: _versionSupported,
    available: _methods.containsAll(_reads),
    actions: Set.unmodifiable({
      for (final action in BootEnvironmentAction.values)
        if (action != BootEnvironmentAction.rename &&
            _methods.contains(_bootMethod(action)) &&
            _synchronousMethods.contains(_bootMethod(action)))
          action,
    }),
  );

  void _guard([BootEnvironmentAction? action]) {
    if (!isCurrent()) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.notAuthenticated,
      );
    }
    if (!_versionSupported) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.available ||
        action != null && !capabilities.supports(action)) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard();
    final result = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    _guard();
    return result;
  }

  Future<BootEnvironmentInventory> _read() async {
    final licensed = await _call('failover.licensed', const []);
    final jobs = await _call('core.get_jobs', const [
      [
        [
          'state',
          'in',
          ['WAITING', 'RUNNING'],
        ],
      ],
      {
        'limit': 129,
        'select': ['id', 'method', 'state'],
      },
    ]);
    final raw = await _call('boot.environment.query', const [
      [],
      {'limit': 129},
    ]);
    if (licensed is! bool ||
        jobs is! List ||
        jobs.length > 128 ||
        raw is! List ||
        raw.length > 128) {
      _bootInvalid();
    }
    var conflicting = false;
    for (final job in jobs) {
      if (job is! Map ||
          job['id'] is! int ||
          (job['id'] as int) < 0 ||
          !_bootText(job['method'], 128) ||
          !{'WAITING', 'RUNNING'}.contains(job['state'])) {
        _bootInvalid();
      }
      final method = job['method'] as String;
      conflicting |=
          method.startsWith('boot.') ||
          method.startsWith('update.') ||
          method.startsWith('failover.') ||
          method == 'system.reboot' ||
          method == 'system.shutdown';
    }
    final environments = <BootEnvironmentSnapshot>[];
    final names = <String>{};
    final datasets = <String>{};
    for (final value in raw) {
      final snapshot = _bootParse(value);
      if (!names.add(snapshot.id) || !datasets.add(snapshot.dataset)) {
        _bootInvalid();
      }
      environments.add(snapshot);
    }
    if (environments.isNotEmpty &&
        (environments.where((e) => e.active).length != 1 ||
            environments.where((e) => e.activated).length != 1 ||
            environments
                    .map((e) => e.dataset.split('/').first)
                    .toSet()
                    .length !=
                1)) {
      _bootInvalid();
    }
    environments.sort((a, b) => a.id.compareTo(b.id));
    return BootEnvironmentInventory(
      environments: environments,
      failoverLicensed: licensed,
      conflictingJob: conflicting,
    );
  }

  Future<BootEnvironmentInventory> load() async {
    _guard();
    if (_calling || isOtherMutationBusy()) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.busy,
      );
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final inventory = await _read();
      _inventories.add(inventory);
      return inventory;
    } on BootEnvironmentsException {
      rethrow;
    } on Object {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<BootEnvironmentReview> review(BootEnvironmentRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.busy,
      );
    }
    if (!_inventories.contains(request.inventory)) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.staleReview,
      );
    }
    if (request.validationError != null) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    try {
      final fresh = await _read();
      if (!_bootSameInventory(request.inventory, fresh) ||
          fresh.blockedReason != null) {
        throw const BootEnvironmentsException(
          BootEnvironmentsExceptionReason.staleReview,
        );
      }
      final review = BootEnvironmentReview._(request);
      _reviews.clear();
      _reviews[review] = fresh;
      return review;
    } on BootEnvironmentsException {
      rethrow;
    } on Object {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<BootEnvironmentResult> execute(BootEnvironmentReview review) async {
    final request = review.request;
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.busy,
      );
    }
    final baseline = _reviews.remove(review);
    if (baseline == null) {
      throw const BootEnvironmentsException(
        BootEnvironmentsExceptionReason.staleReview,
      );
    }
    _calling = true;
    var sent = false;
    try {
      final fresh = await _read();
      if (!_bootSameInventory(baseline, fresh) ||
          fresh.blockedReason != null ||
          request.validationError != null) {
        throw const BootEnvironmentsException(
          BootEnvironmentsExceptionReason.staleReview,
        );
      }
      _guard(request.action);
      if (isOtherMutationBusy()) {
        throw const BootEnvironmentsException(
          BootEnvironmentsExceptionReason.busy,
        );
      }
      final argument = <String, Object?>{
        'id': request.snapshot.id,
        if (request.action == BootEnvironmentAction.clone)
          'target': request.targetName,
        if (request.action == BootEnvironmentAction.keep) 'value': request.keep,
      };
      sent = true;
      final acknowledgement = await _call(_bootMethod(request.action), [
        argument,
      ]);
      BootEnvironmentSnapshot? returned;
      if (request.action == BootEnvironmentAction.delete) {
        if (acknowledgement != null) return _unknown();
      } else {
        // These methods are synchronous on 25.10. No integer is an owned job.
        returned = _bootParse(acknowledgement);
      }
      final after = await _read();
      if (!_verify(request, baseline, after, returned)) return _unknown();
      _inventories.clear();
      _reviews.clear();
      return BootEnvironmentResult(
        outcome: BootEnvironmentOutcome.verified,
        message: request.action == BootEnvironmentAction.activate
            ? 'The next-boot selection was verified. The currently running environment was not changed; no reboot was requested.'
            : 'The requested boot-environment change was independently verified.',
      );
    } on BootEnvironmentsException catch (error) {
      if (sent) return _unknown();
      return BootEnvironmentResult(
        outcome: BootEnvironmentOutcome.rejected,
        message: error.userMessage,
      );
    } on Object {
      if (sent) return _unknown();
      return const BootEnvironmentResult(
        outcome: BootEnvironmentOutcome.rejected,
        message:
            'Preflight checks failed. No boot-environment change was sent.',
      );
    } finally {
      _calling = false;
    }
  }

  BootEnvironmentResult _unknown() {
    _uncertain = true;
    _inventories.clear();
    _reviews.clear();
    return const BootEnvironmentResult(
      outcome: BootEnvironmentOutcome.unknown,
      message: 'The operation may have applied, but its outcome could not be verified. Do not retry. Inspect the original server in TrueNAS and reconnect before further changes.',
    );
  }

  bool _verify(
    BootEnvironmentRequest request,
    BootEnvironmentInventory before,
    BootEnvironmentInventory after,
    BootEnvironmentSnapshot? returned,
  ) {
    if (after.blockedReason != null) return false;
    final oldRows = {for (final row in before.environments) row.id: row};
    final newRows = {for (final row in after.environments) row.id: row};
    final old = request.snapshot;
    if (request.action == BootEnvironmentAction.delete) {
      if (newRows.containsKey(old.id) || newRows.length != oldRows.length - 1) {
        return false;
      }
      oldRows.remove(old.id);
    } else if (request.action == BootEnvironmentAction.clone) {
      final target = newRows.remove(request.targetName);
      if (target == null ||
          returned == null ||
          !_bootSameRow(target, returned) ||
          target.active ||
          target.activated ||
          !target.canActivate ||
          target.dataset !=
              '${old.dataset.substring(0, old.dataset.lastIndexOf('/'))}/${request.targetName}') {
        return false;
      }
    } else {
      final current = newRows[old.id];
      if (current == null ||
          returned == null ||
          !_bootSameRow(current, returned) ||
          !_bootSameIdentity(old, current) ||
          current.active != old.active ||
          current.canActivate != old.canActivate) {
        return false;
      }
      if (request.action == BootEnvironmentAction.keep) {
        if (current.keep != request.keep ||
            current.activated != old.activated) {
          return false;
        }
        oldRows.remove(old.id);
        newRows.remove(old.id);
      } else if (request.action == BootEnvironmentAction.activate) {
        if (!current.activated || current.keep != old.keep) return false;
        for (final row in oldRows.values) {
          final updated = newRows[row.id];
          if (updated == null ||
              !_bootSameRow(row, updated, ignoreActivated: true) ||
              updated.activated != (row.id == old.id)) {
            return false;
          }
        }
        return newRows.length == oldRows.length;
      } else {
        return false;
      }
    }
    return oldRows.length == newRows.length &&
        oldRows.entries.every((entry) {
          final next = newRows[entry.key];
          return next != null && _bootSameRow(entry.value, next);
        });
  }
}

String _bootMethod(BootEnvironmentAction action) => switch (action) {
  BootEnvironmentAction.clone => 'boot.environment.clone',
  BootEnvironmentAction.keep => 'boot.environment.keep',
  BootEnvironmentAction.activate => 'boot.environment.activate',
  BootEnvironmentAction.delete => 'boot.environment.destroy',
  BootEnvironmentAction.rename => '',
};

bool _bootText(Object? value, int maximum) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= maximum &&
    !RegExp(
      r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
    ).hasMatch(value);
bool _bootNewName(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$').stringMatch(value) == value;

BootEnvironmentSnapshot _bootParse(Object? raw) {
  if (raw is! Map ||
      !_bootText(raw['id'], 128) ||
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')
              .stringMatch(raw['id'] as String) !=
          raw['id'] ||
      !_bootText(raw['dataset'], 300) ||
      !_bootText(raw['created'], 64) ||
      raw['used_bytes'] is! int ||
      (raw['used_bytes'] as int) < 0 ||
      (raw['used_bytes'] as int) > 9007199254740991 ||
      raw['active'] is! bool ||
      raw['activated'] is! bool ||
      raw['keep'] is! bool ||
      raw['can_activate'] is! bool) {
    _bootInvalid();
  }
  final dataset = raw['dataset'] as String;
  final segments = dataset.split('/');
  final created = raw['created'] as String;
  if (segments.length != 3 ||
      !_bootNewName(segments.first) ||
      segments[1] != 'ROOT' ||
      segments[2] != raw['id'] ||
      !_bootValidCreation(created)) {
    _bootInvalid();
  }
  return BootEnvironmentSnapshot(
    id: raw['id'] as String,
    dataset: dataset,
    created: created,
    usedBytes: raw['used_bytes'] as int,
    active: raw['active'] as bool,
    activated: raw['activated'] as bool,
    keep: raw['keep'] as bool,
    canActivate: raw['can_activate'] as bool,
  );
}

bool _bootValidCreation(String value) {
  final match = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-](\d{2}):(\d{2}))?$',
  ).firstMatch(value);
  if (match == null || DateTime.tryParse(value) == null) return false;
  final prefix = value.substring(0, 19);
  final date = DateTime.tryParse('${prefix}Z');
  // DateTime.parse normalizes values such as February 30; identity must not.
  if (date == null ||
      date.year < 1970 ||
      date.toIso8601String().substring(0, 19) != prefix) {
    return false;
  }
  return match.group(1) == null ||
      int.parse(match.group(1)!) <= 23 && int.parse(match.group(2)!) <= 59;
}

bool _bootSameIdentity(BootEnvironmentSnapshot a, BootEnvironmentSnapshot b) =>
    a.id == b.id && a.dataset == b.dataset && a.created == b.created;
bool _bootSameRow(
  BootEnvironmentSnapshot a,
  BootEnvironmentSnapshot b, {
  bool ignoreActivated = false,
}) =>
    _bootSameIdentity(a, b) &&
    a.active == b.active &&
    (ignoreActivated || a.activated == b.activated) &&
    a.keep == b.keep &&
    a.canActivate == b.canActivate;
bool _bootSameInventory(
  BootEnvironmentInventory a,
  BootEnvironmentInventory b,
) =>
    a.failoverLicensed == b.failoverLicensed &&
    a.conflictingJob == b.conflictingJob &&
    a.environments.length == b.environments.length &&
    a.environments.every(
      (row) => b.environments.any((next) => _bootSameRow(row, next)),
    );
Never _bootInvalid() => throw const BootEnvironmentsException(
  BootEnvironmentsExceptionReason.invalidResponse,
);
