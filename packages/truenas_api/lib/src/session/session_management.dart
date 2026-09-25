part of 'true_nas_session_repository.dart';

/// Explicit mutation capability; the inventory query allowlist stays unchanged.
abstract interface class AuthenticatedSessionManagement {
  ManagementCapabilities get managementCapabilities;
  Future<ManagementResult> execute(ManagementCommand command);

  /// One ID-filtered read with a deadline. Never repeats the original mutation.
  Future<ManagementResult> pollJob(ManagementJobSubmitted job);
}

enum ManagementAction {
  serviceStart,
  serviceStop,
  serviceRestart,
  datasetCreate,
  datasetDelete,
  snapshotCreate,
}

enum ServiceControlAction { start, stop, restart }

sealed class ManagementCommand {
  const ManagementCommand();
  ManagementAction get managementAction;
  String get target;
}

final class ServiceControlCommand extends ManagementCommand {
  const ServiceControlCommand({required this.service, required this.action});
  final String service;
  final ServiceControlAction action;
  @override
  ManagementAction get managementAction => switch (action) {
    ServiceControlAction.start => ManagementAction.serviceStart,
    ServiceControlAction.stop => ManagementAction.serviceStop,
    ServiceControlAction.restart => ManagementAction.serviceRestart,
  };
  @override
  String get target => service;
}

final class CreateDatasetCommand extends ManagementCommand {
  const CreateDatasetCommand({required this.parent, required this.name});
  final String parent;
  final String name;
  @override
  ManagementAction get managementAction => ManagementAction.datasetCreate;
  @override
  String get target => '$parent/$name';
}

final class DeleteDatasetCommand extends ManagementCommand {
  const DeleteDatasetCommand({required this.dataset});
  final String dataset;
  @override
  ManagementAction get managementAction => ManagementAction.datasetDelete;
  @override
  String get target => dataset;
}

final class CreateSnapshotCommand extends ManagementCommand {
  const CreateSnapshotCommand({required this.dataset, required this.name});
  final String dataset;
  final String name;
  @override
  ManagementAction get managementAction => ManagementAction.snapshotCreate;
  @override
  String get target => '$dataset@$name';
}

enum ManagementExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  invalidInput,
  busy,
  attachedResources,
  staleSession,
  preflightFailed,
}

final class ManagementException implements Exception {
  const ManagementException(this.reason);
  final ManagementExceptionReason reason;
  String get userMessage => switch (reason) {
    ManagementExceptionReason.notAuthenticated =>
      'Connect to a server before managing it.',
    ManagementExceptionReason.unsupportedVersion =>
      'Management is unavailable for this server version.',
    ManagementExceptionReason.unavailableMethod =>
      'This action is unavailable for this server or account.',
    ManagementExceptionReason.invalidInput =>
      'Choose a valid service or a non-system dataset and name.',
    ManagementExceptionReason.busy =>
      'Another management operation is pending or needs verification.',
    ManagementExceptionReason.attachedResources => 'This dataset is used by shares or tasks. Remove those dependencies in TrueNAS first.',
    ManagementExceptionReason.staleSession =>
      'The server connection changed. Review the action again.',
    ManagementExceptionReason.preflightFailed =>
      'Unable to verify dataset dependencies. Nothing was deleted.',
  };
  @override
  String toString() => userMessage;
}

enum ManagementStatus { completed, submitted, failed, unknown }

enum ManagementFailureReason {
  permissionDenied,
  rejected,
  operationFailed,
  aborted,
}

sealed class ManagementResult {
  const ManagementResult(this.command);
  final ManagementCommand command;
  ManagementStatus get status;
  String get userMessage;
}

final class ManagementCompleted extends ManagementResult {
  const ManagementCompleted(super.command);
  @override
  ManagementStatus get status => ManagementStatus.completed;
  @override
  String get userMessage => 'The server confirmed that the action completed.';
}

final class ManagementJobSubmitted extends ManagementResult {
  const ManagementJobSubmitted(super.command, {required this.jobId});
  final int jobId;
  @override
  ManagementStatus get status => ManagementStatus.submitted;
  @override
  String get userMessage =>
      'The server accepted the job. Completion is being checked.';
}

final class ManagementFailed extends ManagementResult {
  const ManagementFailed(super.command, {required this.reason});
  final ManagementFailureReason reason;
  @override
  ManagementStatus get status => ManagementStatus.failed;
  @override
  String get userMessage => switch (reason) {
    ManagementFailureReason.permissionDenied =>
      'The account does not have permission for this action.',
    ManagementFailureReason.rejected =>
      'The server rejected the action. Check the target and its dependencies.',
    ManagementFailureReason.operationFailed =>
      'The server reported that the action failed.',
    ManagementFailureReason.aborted =>
      'The server reported that the job was aborted.',
  };
}

final class ManagementOutcomeUnknown extends ManagementResult {
  const ManagementOutcomeUnknown(super.command, {this.jobId});
  final int? jobId;
  @override
  ManagementStatus get status => ManagementStatus.unknown;
  @override
  String get userMessage =>
      'Completion could not be confirmed. Inspect the original server and reconnect before another mutation. Do not repeat this request.';
}

final class ManagementCapabilities {
  const ManagementCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.availableActions,
  });
  const ManagementCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      availableActions = const <ManagementAction>{};
  final bool connected;
  final bool versionSupported;
  final Set<ManagementAction> availableActions;
  bool supports(ManagementAction action) =>
      connected && versionSupported && availableActions.contains(action);
}

// Official contracts: api.truenas.com/v25.10 and /v26.0 method pages.
// 25.04 legacy methods: truenas/middleware tag TS-25.04.2,
// plugins/service.py, plugins/pool_/dataset.py, plugins/zfs_/snapshot.py.
enum _ManagementVersion { v2504, v2510, v260 }

_ManagementVersion? _managementVersion(String version) {
  final match = RegExp(
    r'^(?:TrueNAS(?:-SCALE)?-)?(25\.04|25\.10|26\.0)(?:\.[0-9]+)*(?:-(?:RELEASE|U[0-9]+))?$',
  ).firstMatch(version);
  return switch (match?.group(0) == version ? match?.group(1) : null) {
    '25.04' => _ManagementVersion.v2504,
    '25.10' => _ManagementVersion.v2510,
    '26.0' => _ManagementVersion.v260,
    _ => null,
  };
}

final class _SessionManagement {
  _SessionManagement({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.requestTimeout,
  }) : version = _managementVersion(summary.version),
       methods = Set<String>.unmodifiable(summary.availableMethodNames);
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final Duration requestTimeout;
  final _ManagementVersion? version;
  final Set<String> methods;
  final _jobs = <ManagementJobSubmitted, ManagementResult>{};
  bool _submitting = false;
  bool _unknownMutation = false;
  bool get isBusy =>
      _submitting ||
      _unknownMutation ||
      _jobs.values.any((result) => result is ManagementJobSubmitted);

  ManagementOutcomeUnknown _unknown(ManagementCommand command) {
    _unknownMutation = true;
    return ManagementOutcomeUnknown(command);
  }

  String _method(ManagementAction action) => switch (action) {
    ManagementAction.serviceStart => _serviceMethod('start'),
    ManagementAction.serviceStop => _serviceMethod('stop'),
    ManagementAction.serviceRestart => _serviceMethod('restart'),
    ManagementAction.datasetCreate => 'pool.dataset.create',
    ManagementAction.datasetDelete => 'pool.dataset.delete',
    ManagementAction.snapshotCreate =>
      version == _ManagementVersion.v2504
          ? 'zfs.snapshot.create'
          : 'pool.snapshot.create',
  };
  String _serviceMethod(String verb) =>
      version == _ManagementVersion.v2504 ? 'service.$verb' : 'service.control';

  ManagementCapabilities get capabilities => ManagementCapabilities(
    connected: isCurrent(),
    versionSupported: version != null,
    availableActions: Set<ManagementAction>.unmodifiable(
      ManagementAction.values.where(
        (action) =>
            methods.contains(_method(action)) &&
            (action != ManagementAction.datasetDelete ||
                methods.contains('pool.dataset.attachments')) &&
            (!{
                  ManagementAction.serviceStart,
                  ManagementAction.serviceStop,
                  ManagementAction.serviceRestart,
                }.contains(action) ||
                version == _ManagementVersion.v2504 ||
                methods.contains('core.get_jobs')),
      ),
    ),
  );

  ManagementAction _action(ManagementCommand command) => switch (command) {
    ServiceControlCommand(:final action) => switch (action) {
      ServiceControlAction.start => ManagementAction.serviceStart,
      ServiceControlAction.stop => ManagementAction.serviceStop,
      ServiceControlAction.restart => ManagementAction.serviceRestart,
    },
    CreateDatasetCommand() => ManagementAction.datasetCreate,
    DeleteDatasetCommand() => ManagementAction.datasetDelete,
    CreateSnapshotCommand() => ManagementAction.snapshotCreate,
  };

  void _requireCurrent() {
    if (!isCurrent()) {
      throw const ManagementException(ManagementExceptionReason.staleSession);
    }
  }

  Future<Object?> _call(String method, List<Object?> params) =>
      client.call(method, id: nextId(), params: params).timeout(requestTimeout);

  Future<ManagementResult> execute(ManagementCommand command) async {
    _requireCurrent();
    if (version == null) {
      throw const ManagementException(
        ManagementExceptionReason.unsupportedVersion,
      );
    }
    final action = _action(command);
    if (!capabilities.supports(action)) {
      throw const ManagementException(
        ManagementExceptionReason.unavailableMethod,
      );
    }
    _validate(command);
    if (isBusy) {
      throw const ManagementException(ManagementExceptionReason.busy);
    }
    _submitting = true;
    try {
      if (command is DeleteDatasetCommand) {
        await _checkAttachments(command.dataset);
      }
      _requireCurrent();
      try {
        final result = await _call(_method(action), _params(command));
        if (!isCurrent()) return _unknown(command);
        if (command is ServiceControlCommand &&
            version != _ManagementVersion.v2504) {
          if (result is! int || result <= 0) {
            return _unknown(command);
          }
          final submitted = ManagementJobSubmitted(command, jobId: result);
          _jobs[submitted] = submitted;
          return submitted;
        }
        final direct = _directResult(command, result);
        if (direct is ManagementOutcomeUnknown) return _unknown(command);
        return direct;
      } on JsonRpcRemoteException catch (error) {
        final reason = _failureReason(error);
        if (reason != ManagementFailureReason.permissionDenied) {
          return _unknown(command);
        }
        return ManagementFailed(command, reason: reason);
      } on Object {
        return _unknown(command);
      }
    } finally {
      _submitting = false;
    }
  }

  Future<void> _checkAttachments(String dataset) async {
    // TrueNAS can remove attachment delegates during deletion even with force
    // false. Refuse known dependencies before sending delete. The upstream API
    // has no atomic "delete only if unattached" flag: another administrator
    // must not create shares or tasks for this dataset during this operation.
    final Object? attachments;
    try {
      attachments = await _call('pool.dataset.attachments', [dataset]);
    } on Object {
      throw const ManagementException(
        ManagementExceptionReason.preflightFailed,
      );
    }
    _requireCurrent();
    if (attachments is! List) {
      throw const ManagementException(
        ManagementExceptionReason.preflightFailed,
      );
    }
    if (attachments.isNotEmpty) {
      throw const ManagementException(
        ManagementExceptionReason.attachedResources,
      );
    }
  }

  List<Object?> _params(ManagementCommand command) => switch (command) {
    ServiceControlCommand(:final service, :final action) =>
      version == _ManagementVersion.v2504
          ? [
              service,
              {'silent': false},
            ]
          : [
              action.name.toUpperCase(),
              service,
              {'silent': false, 'timeout': 30},
            ],
    CreateDatasetCommand(:final target) => [
      {
        'name': target,
        'type': 'FILESYSTEM',
        'create_ancestors': false,
        'inherit_encryption': true,
      },
    ],
    DeleteDatasetCommand(:final dataset) => [
      dataset,
      {'recursive': false, 'force': false},
    ],
    CreateSnapshotCommand(:final dataset, :final name) => [
      {'dataset': dataset, 'name': name, 'recursive': false},
    ],
  };

  ManagementResult _directResult(ManagementCommand command, Object? value) {
    if (command is ServiceControlCommand || command is DeleteDatasetCommand) {
      if (value == true) return ManagementCompleted(command);
      if (value == false) {
        return ManagementFailed(
          command,
          reason: ManagementFailureReason.operationFailed,
        );
      }
    } else if (value is Map && value['id'] == command.target) {
      return ManagementCompleted(command);
    }
    return ManagementOutcomeUnknown(command);
  }

  Future<ManagementResult> pollJob(ManagementJobSubmitted job) async {
    // Identity binding prevents polling a forged ID or a job from another NAS.
    final known = _jobs[job];
    if (!isCurrent() || known == null || !methods.contains('core.get_jobs')) {
      return ManagementOutcomeUnknown(job.command, jobId: job.jobId);
    }
    if (known is! ManagementJobSubmitted) return known;
    try {
      final rows = await _call('core.get_jobs', [
        [
          ['id', '=', job.jobId],
        ],
        {
          'limit': 1,
          'select': ['id', 'method', 'state', 'result'],
        },
      ]);
      if (!isCurrent() || rows is! List || rows.length != 1) {
        return ManagementOutcomeUnknown(job.command, jobId: job.jobId);
      }
      final row = rows.single;
      if (row is! Map ||
          row['id'] is! int ||
          row['id'] != job.jobId ||
          row['method'] != 'service.control') {
        return ManagementOutcomeUnknown(job.command, jobId: job.jobId);
      }
      final result = switch (row['state']) {
        'WAITING' || 'RUNNING' => job,
        'SUCCESS' => _directResult(job.command, row['result']),
        'FAILED' => ManagementFailed(
          job.command,
          reason: ManagementFailureReason.operationFailed,
        ),
        'ABORTED' => ManagementFailed(
          job.command,
          reason: ManagementFailureReason.aborted,
        ),
        _ => ManagementOutcomeUnknown(job.command, jobId: job.jobId),
      };
      if (result is ManagementCompleted || result is ManagementFailed) {
        _jobs[job] = result;
      }
      return result;
    } on Object {
      return ManagementOutcomeUnknown(job.command, jobId: job.jobId);
    }
  }

  ManagementFailureReason _failureReason(JsonRpcRemoteException error) {
    final data = error.data;
    final errno = data is Map ? data['errno'] : null;
    // -32001 is TrueNAS's generic method-call error, not an authorization code.
    // Only explicit EPERM/EACCES prove that the account lacks permission.
    return errno is int && (errno == 1 || errno == 13)
        ? ManagementFailureReason.permissionDenied
        : ManagementFailureReason.rejected;
  }

  static final _component = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,127}$');
  static bool _validComponent(String value) =>
      _component.stringMatch(value) == value;
  static bool _validDataset(String value) {
    final parts = value.split('/');
    return value.length <= 240 &&
        parts.every(_validComponent) &&
        !parts.any(
          const {
            'boot-pool',
            'freenas-boot',
            'ix-apps',
            'ix-applications',
          }.contains,
        );
  }

  void _validate(ManagementCommand command) {
    final valid = switch (command) {
      ServiceControlCommand(:final service) =>
        RegExp(r'^[a-z][a-z0-9_]{0,63}$').stringMatch(service) == service,
      CreateDatasetCommand(:final parent, :final name, :final target) =>
        _validDataset(parent) && _validComponent(name) && _validDataset(target),
      DeleteDatasetCommand(:final dataset) =>
        _validDataset(dataset) && dataset.contains('/'),
      CreateSnapshotCommand(:final dataset, :final name, :final target) =>
        _validDataset(dataset) && _validComponent(name) && target.length <= 255,
    };
    if (!valid) {
      throw const ManagementException(ManagementExceptionReason.invalidInput);
    }
  }
}
