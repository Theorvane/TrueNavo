import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../configuration_backup/configuration_backup_file.dart';
import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'audit_export_archive.dart';

final auditExportSessionProvider = Provider<AuthenticatedAuditExportSession?>((
  ref,
) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedAuditExportSession
      ? repository as AuthenticatedAuditExportSession
      : null;
});

enum AuditExportStatus {
  idle,
  submitting,
  pending,
  downloading,
  saving,
  saved,
  cancelled,
  failed,
  rejected,
  unknown,
}

final class AuditExportState {
  const AuditExportState({
    this.status = AuditExportStatus.idle,
    this.message,
    this.server,
    this.operation,
  });
  final AuditExportStatus status;
  final String? message, server;
  final AuditExportOperation? operation;
  bool get busy => const {
    AuditExportStatus.submitting,
    AuditExportStatus.downloading,
    AuditExportStatus.saving,
  }.contains(status);
  bool get pending => status == AuditExportStatus.pending;
  bool get unknown => status == AuditExportStatus.unknown;
  bool get locked => busy || pending || unknown;
}

final auditExportControllerProvider =
    NotifierProvider<AuditExportController, AuditExportState>(
      AuditExportController.new,
    );

class AuditExportController extends Notifier<AuditExportState> {
  final Map<AuditExportReview, bool> _used = {};
  AuthenticatedSession? _operationSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;

  @override
  AuditExportState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (_operationSession == null || identical(_operationSession, next)) {
        return;
      }
      _generation++;
      if (state.locked) {
        state = AuditExportState(
          status: AuditExportStatus.unknown,
          server: state.server,
          operation: state.operation,
          message: 'The connection changed after an audit report job may have started. No file is offered. Inspect both jobs on the original server, then reconnect before acknowledging.',
        );
      } else {
        _release();
        state = const AuditExportState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const AuditExportState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required AuditExportReview review,
    required String confirmation,
    required bool Function() routeCurrent,
  }) async {
    if (state.locked || _used[review] == true) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final api = expectedSession.repository;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed ||
        expectedSession.endpoint == null ||
        review.endpoint != expectedSession.endpoint ||
        confirmation != review.target ||
        review.request.validationError != null ||
        !routeCurrent() ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedAuditExportSession ||
        !(api as AuthenticatedAuditExportSession)
            .auditExportCapabilities
            .canExport ||
        !ref.read(configurationBackupFileSaverProvider).supported) {
      state = const AuditExportState(
        status: AuditExportStatus.rejected,
        message: 'The current server, exact target, disclosures or protected file destination is missing. No report was requested.',
      );
      return;
    }
    final exportApi = api as AuthenticatedAuditExportSession;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const AuditExportState(
        status: AuditExportStatus.rejected,
        message: 'Another server operation is pending or unverified.',
      );
      return;
    }
    _used[review] = true;
    _operationSession = expectedSession;
    final generation = ++_generation;
    state = AuditExportState(
      status: AuditExportStatus.submitting,
      server: expectedSession.endpoint,
      message: 'Submitting one reviewed report job. It will not be replayed.',
    );
    bool current() =>
        ref.mounted &&
        generation == _generation &&
        routeCurrent() &&
        identical(expectedSession, ref.read(dashboardActiveSessionProvider));
    try {
      final result = await exportApi.executeAuditExport(
        review,
        confirmation,
        isCurrent: current,
      );
      if (!ref.mounted || generation != _generation) return;
      _accept(result, server: expectedSession.endpoint!);
    } on Object {
      _fence(
        'Report submission could not be verified. Remote details were withheld and no retry is automatic.',
      );
    }
  }

  Future<void> poll({required bool Function() routeCurrent}) async {
    final session = _operationSession;
    final operation = state.operation;
    if (!state.pending ||
        session == null ||
        operation == null ||
        !routeCurrent() ||
        !identical(session, ref.read(dashboardActiveSessionProvider)) ||
        session.repository is! AuthenticatedAuditExportSession) {
      return;
    }
    final generation = _generation;
    final api = session.repository as AuthenticatedAuditExportSession;
    state = AuditExportState(
      status: AuditExportStatus.downloading,
      server: state.server,
      operation: operation,
      message: 'Checking the owned report job. A successful report starts one bounded download job.',
    );
    bool current() =>
        ref.mounted &&
        generation == _generation &&
        routeCurrent() &&
        identical(session, ref.read(dashboardActiveSessionProvider));
    AuditExportArtifact? artifact;
    Uint8List? bytes;
    try {
      final result = await api.pollAuditExport(operation, isCurrent: current);
      artifact = result.artifact;
      if (!ref.mounted || generation != _generation) return;
      if (result.outcome != AuditExportOutcome.completed) {
        _accept(result, server: state.server!);
        return;
      }
      if (!current() ||
          artifact == null ||
          artifact.byteLength < 3 ||
          artifact.byteLength > 16 * 1024 * 1024) {
        _fence(
          'The completed report artifact did not match the reviewed bounded download. It was discarded.',
        );
        return;
      }
      bytes = artifact.takeBytes();
      final archive = const AuditExportArchiveVerifier().verify(
        compressed: bytes,
        filename: artifact.filename,
        format: operation.format,
      );
      if (archive == null) {
        _fence(
          'The gzip or tar contents did not match the reviewed TrueNAS audit report structure. No file is offered and no retry is automatic.',
          operation: operation,
        );
        return;
      }
      state = AuditExportState(
        status: AuditExportStatus.saving,
        server: state.server,
        operation: operation,
        message:
            'Verified ${archive.rowCount} bounded report rows and ${archive.decodedBytes} decoded bytes. Choose a protected destination; its provider may use cloud storage.',
      );
      final saved = await ref
          .read(configurationBackupFileSaverProvider)
          .save(bytes: bytes, filename: artifact.filename, isCurrent: current);
      if (!ref.mounted || generation != _generation) return;
      if (!current()) {
        _fence(
          'The route or connection changed during document handoff. The buffer was discarded, but a selected destination may be empty or partial. Inspect it independently before reconnecting.',
          operation: operation,
        );
        return;
      }
      final status = switch (saved) {
        ConfigurationBackupSaveOutcome.saved => AuditExportStatus.saved,
        ConfigurationBackupSaveOutcome.cancelled => AuditExportStatus.cancelled,
        ConfigurationBackupSaveOutcome.failed ||
        ConfigurationBackupSaveOutcome.unsupported => AuditExportStatus.failed,
      };
      state = AuditExportState(
        status: status,
        server: state.server,
        operation: operation,
        message: status == AuditExportStatus.saved
            ? 'The document provider reported the structurally verified sensitive report saved. Semantic completeness, authenticity and off-device durability were not verified.'
            : 'The file was not confirmed saved. A selected destination may contain an empty or partial file; inspect it independently.',
      );
      _release();
    } on Object {
      _fence(
        'Report job, download job or file handoff could not be verified. No retry is automatic; inspect the original server and any selected destination.',
      );
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      artifact?.dispose();
    }
  }

  void _accept(AuditExportResult result, {required String server}) {
    switch (result.outcome) {
      case AuditExportOutcome.pending:
        if (result.operation == null) {
          _fence(
            'The server reported a pending export without a verifiable job identity.',
          );
          return;
        }
        state = AuditExportState(
          status: AuditExportStatus.pending,
          server: server,
          operation: result.operation,
          message: result.message,
        );
        return;
      case AuditExportOutcome.completed:
        _fence(
          'An audit report completed outside the protected download handoff.',
        );
        return;
      case AuditExportOutcome.rejected:
        state = AuditExportState(
          status: AuditExportStatus.rejected,
          server: server,
          message: result.message,
        );
        _release();
        return;
      case AuditExportOutcome.unknown:
        _fence(result.message, operation: result.operation);
    }
  }

  void _fence(String message, {AuditExportOperation? operation}) {
    state = AuditExportState(
      status: AuditExportStatus.unknown,
      server: state.server ?? _operationSession?.endpoint,
      operation: operation ?? state.operation,
      message: message,
    );
  }

  bool get canAcknowledge {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unknown &&
        current?.endpoint != null &&
        current!.endpoint == state.server &&
        !identical(current, _operationSession);
  }

  void acknowledgeAfterReconnect() {
    if (!canAcknowledge) return;
    _release();
    state = const AuditExportState(
      status: AuditExportStatus.cancelled,
      message: 'Original-server inspection acknowledged after reconnect.',
    );
  }

  void _release() {
    final owner = _owner;
    if (owner != null) _lock?.release(owner);
    _owner = null;
    _lock = null;
    _operationSession = null;
  }
}
