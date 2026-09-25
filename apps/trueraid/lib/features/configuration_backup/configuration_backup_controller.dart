import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'configuration_backup_file.dart';

final configurationBackupSessionProvider =
    Provider<AuthenticatedConfigurationBackupSession?>((ref) {
      final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repository is AuthenticatedConfigurationBackupSession
          ? repository as AuthenticatedConfigurationBackupSession
          : null;
    });

final configurationBackupInventoryProvider =
    FutureProvider<ConfigurationBackupInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = ref.watch(configurationBackupSessionProvider);
      if (session?.endpoint == null ||
          api == null ||
          ref.read(configurationBackupControllerProvider).locked) {
        throw StateError(
          'A current, unfenced configuration backup session is required.',
        );
      }
      final inventory = await api.loadConfigurationBackup();
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          inventory.endpoint != session!.endpoint) {
        throw StateError(
          'The configuration backup inventory connection changed.',
        );
      }
      return inventory;
    }, retry: (_, _) => null);

enum ConfigurationBackupStatus {
  idle,
  exporting,
  saving,
  saved,
  cancelled,
  failed,
  rejected,
  unknown,
}

/// Public status only: never place an artifact, byte buffer, URL or token here.
final class ConfigurationBackupState {
  const ConfigurationBackupState({
    this.status = ConfigurationBackupStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.jobId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final ConfigurationBackupStatus status;
  final String? message, server, hostId, verificationMessage;
  final int? jobId;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == ConfigurationBackupStatus.exporting ||
      status == ConfigurationBackupStatus.saving;
  bool get unknown => status == ConfigurationBackupStatus.unknown;
  bool get locked => busy || unknown;
  ConfigurationBackupState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => ConfigurationBackupState(
    status: status,
    message: this.message,
    server: server,
    hostId: hostId,
    jobId: jobId,
    connectionCurrent: connectionCurrent,
    verifying: verifying,
    hostVerified: verified,
    verificationMessage: message,
  );
}

final configurationBackupControllerProvider =
    NotifierProvider<ConfigurationBackupController, ConfigurationBackupState>(
      ConfigurationBackupController.new,
    );

class ConfigurationBackupController extends Notifier<ConfigurationBackupState> {
  AuthenticatedSession? _session, _verifiedSession;
  ServerOperationLock? _lock;
  Object? _owner;
  ConfigurationBackupFileSaver? _activeSaver;
  int? _activeSaveGeneration;
  int? _pendingGeneration;
  int _generation = 0, _verificationGeneration = 0;
  final _used = Expando<bool>();

  @override
  ConfigurationBackupState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next == AppLifecycleState.resumed) return;
        _verificationGeneration++;
        _verifiedSession = null;
        if (state.verifying || state.hostVerified) {
          state = state.verification(
            message: 'Reconnected-host verification expired. Verify explicitly again while the app is active.',
          );
        }
        if (state.status == ConfigurationBackupStatus.exporting) {
          _fence(
            'The app became inactive during export. Any returned artifact is discarded. Inspect original-server jobs before reconnecting; no export is replayed.',
          );
        }
        // The user-selected Android document picker legitimately backgrounds the
        // app, but only after reviewed export has completed and saving begins.
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _verificationGeneration++;
      _verifiedSession = null;
      if (state.locked) {
        _fence(
          'The connection changed during an export or unverified outcome. Inspect original-server jobs. A selected destination may contain an empty or partial file; no automatic deletion or retry occurs.',
          current: identical(_session, next),
        );
      } else {
        _generation++;
        _session = null;
        state = const ConfigurationBackupState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _cancelSave();
      _release();
    });
    return const ConfigurationBackupState();
  }

  void _cancelSave() {
    final saver = _activeSaver;
    _activeSaver = null;
    try {
      saver?.cancel();
    } on Object {
      /* No raw platform details. */
    }
  }

  void _fence(String message, {bool? current}) {
    _generation++;
    _cancelSave();
    state = ConfigurationBackupState(
      status: ConfigurationBackupStatus.unknown,
      message: message,
      server: state.server,
      hostId: state.hostId,
      jobId: state.jobId,
      connectionCurrent: current ?? state.connectionCurrent,
    );
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required ConfigurationBackupReview review,
    required String confirmation,
    required bool confidentialityAccepted,
    required bool secretSeedAccepted,
  }) async {
    if (state.locked || _used[review] == true) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final inventory = ref.read(configurationBackupInventoryProvider);
    final saver = ref.read(configurationBackupFileSaverProvider);
    final api = expectedSession.repository;
    if (!confidentialityAccepted ||
        review.request.includeSecretSeed && !secretSeedAccepted ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed ||
        expectedSession.endpoint == null ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        confirmation != review.target ||
        review.request.validationError != null ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        inventory.isLoading ||
        !identical(inventory.asData?.value, review.request.inventory) ||
        !saver.supported ||
        api is! AuthenticatedConfigurationBackupSession ||
        !(api as AuthenticatedConfigurationBackupSession)
            .configurationBackupCapabilities
            .canExport) {
      state = const ConfigurationBackupState(
        status: ConfigurationBackupStatus.rejected,
        message: 'Consent, current inventory, exact server target or supported secure export is missing. Nothing was exported. Reload and review again.',
      );
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const ConfigurationBackupState(
        status: ConfigurationBackupStatus.rejected,
        message:
            'Another operation is pending or unverified. Nothing was exported.',
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    _pendingGeneration = generation;
    final server = expectedSession.endpoint!,
        hostId = review.request.inventory.hostId;
    state = ConfigurationBackupState(
      status: ConfigurationBackupStatus.exporting,
      server: server,
      hostId: hostId,
      message: 'Exporting reviewed configuration. Do not switch server or leave the app.',
    );
    ConfigurationBackupArtifact? artifact;
    Uint8List? bytes;
    ProviderSubscription<AsyncValue<ConfigurationBackupInventory>>?
    inventoryWatch;
    bool current() {
      if (!ref.mounted ||
          generation != _generation ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          )) {
        return false;
      }
      final latest = ref.read(configurationBackupInventoryProvider);
      if (latest.isLoading ||
          !identical(review.request.inventory, latest.asData?.value)) {
        if (generation == _generation && state.busy) {
          _fence(
            'Backup readiness changed before the artifact could be saved. Returned bytes are discarded and any pending selection is cancelled. Inspect any selected file and original-server jobs before reconnecting.',
          );
        }
        return false;
      }
      return generation == _generation;
    }

    try {
      inventoryWatch = ref.listen(configurationBackupInventoryProvider, (
        _,
        next,
      ) {
        if (generation == _generation &&
            state.busy &&
            (next.isLoading ||
                !identical(review.request.inventory, next.asData?.value))) {
          _fence(
            'Backup readiness changed during export or destination selection. Returned bytes are discarded and any pending selection is cancelled. A selected file may be empty or partial; inspect before reconnecting.',
          );
        }
      });
      final result = await (api as AuthenticatedConfigurationBackupSession)
          .executeConfigurationBackup(review, confirmation);
      artifact = result.artifact;
      if (!current()) return;
      if (result.outcome != ConfigurationBackupOutcome.completed) {
        state = ConfigurationBackupState(
          status: result.outcome == ConfigurationBackupOutcome.unknown
              ? ConfigurationBackupStatus.unknown
              : ConfigurationBackupStatus.rejected,
          server: server,
          hostId: hostId,
          jobId: result.jobId,
          message: result.outcome == ConfigurationBackupOutcome.unknown
              ? 'Export completion could not be verified. No file is offered. Inspect original-server jobs before reconnecting; do not repeat this export.'
              : 'The reviewed export was rejected. No file was saved. Reload and create a new review if appropriate.',
        );
        return;
      }
      final expectedFilename =
          review.request.includeSecretSeed ||
              review.request.includeAuthorizedKeys
          ? 'truenas-configuration.tar'
          : 'truenas-configuration.db';
      if (result.jobId == null ||
          result.jobId! <= 0 ||
          result.jobId! > 9007199254740991 ||
          artifact == null ||
          artifact.isDisposed ||
          artifact.byteLength < 512 ||
          artifact.byteLength > 16 * 1024 * 1024 ||
          artifact.filename != expectedFilename ||
          artifact.includesSecretSeed != review.request.includeSecretSeed ||
          artifact.includesAuthorizedKeys !=
              review.request.includeAuthorizedKeys) {
        state = ConfigurationBackupState(
          status: ConfigurationBackupStatus.unknown,
          server: server,
          hostId: hostId,
          message: 'The completed export artifact did not match the reviewed request. It was discarded. Inspect original-server jobs before reconnecting; no file is offered.',
        );
        return;
      }
      bytes = artifact.takeBytes();
      if (!current()) return;
      _activeSaver = saver;
      _activeSaveGeneration = generation;
      state = ConfigurationBackupState(
        status: ConfigurationBackupStatus.saving,
        server: server,
        hostId: hostId,
        jobId: result.jobId,
        message: 'Choose a trusted destination. A document provider may store the backup in the cloud.',
      );
      final saved = await saver.save(
        bytes: bytes,
        filename: expectedFilename,
        isCurrent: current,
      );
      if (!current()) return;
      final status = switch (saved) {
        ConfigurationBackupSaveOutcome.saved => ConfigurationBackupStatus.saved,
        ConfigurationBackupSaveOutcome.cancelled =>
          ConfigurationBackupStatus.cancelled,
        ConfigurationBackupSaveOutcome.failed ||
        ConfigurationBackupSaveOutcome.unsupported =>
          ConfigurationBackupStatus.failed,
      };
      state = ConfigurationBackupState(
        status: status,
        server: server,
        hostId: hostId,
        jobId: result.jobId,
        message: status == ConfigurationBackupStatus.saved
            ? 'The selected document provider reported the file saved. Restore, recovery, off-device durability and cloud confidentiality have not been verified. No artifact is cached in this app.'
            : 'The file was not confirmed saved. Your selected destination may contain an empty or partial file. Inspect it independently; no automatic deletion, retry or cached artifact is available.',
      );
    } on Object {
      if (current()) {
        state = ConfigurationBackupState(
          status: ConfigurationBackupStatus.unknown,
          server: server,
          hostId: hostId,
          message: 'Export or file-save completion could not be verified. Remote details were withheld. A selected destination may contain an empty or partial file. Inspect it and original-server jobs before reconnecting; no retry is automatic.',
        );
      }
    } finally {
      inventoryWatch?.close();
      // The saver also consumes its buffer. Always wipe our owned view, even
      // when a fake/failed saver does not, and dispose any untaken artifact.
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      artifact?.dispose();
      if (_activeSaveGeneration == generation) {
        _activeSaver = null;
        _activeSaveGeneration = null;
      }
      if (_pendingGeneration == generation) {
        _pendingGeneration = null;
        if (ref.mounted && state.unknown) {
          state = state.verification(
            verifying: state.verifying,
            verified: state.hostVerified,
            message: state.verificationMessage,
          );
        }
      }
      if (current() && !state.locked) _release();
    }
  }

  bool get canVerifyReconnectedServer {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unknown &&
        !state.verifying &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        current!.endpoint == state.server &&
        !identical(current, _session);
  }

  Future<void> verifyReconnectedServer() async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!canVerifyReconnectedServer ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    final session = ref.read(dashboardActiveSessionProvider)!;
    final api = session.repository;
    if (api is! AuthenticatedConfigurationBackupSession) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    ConfigurationBackupInventory? inventory;
    try {
      inventory = await (api as AuthenticatedConfigurationBackupSession)
          .loadConfigurationBackup();
    } on Object {
      /* Fixed result below. */
    }
    if (!ref.mounted ||
        generation != _verificationGeneration ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final verified =
        inventory != null &&
        inventory.endpoint == state.server &&
        inventory.endpoint == session.endpoint &&
        inventory.hostId == state.hostId;
    _verifiedSession = verified ? session : null;
    state = state.verification(
      verified: verified,
      message: verified
          ? 'The reconnected public host identity matches. Independently inspect its jobs and any selected file. This does not establish export success or restore validity.'
          : 'The reconnected host could not be verified as the original machine. Details were withheld. The write lock remains.',
    );
  }

  bool get canAcknowledge =>
      _pendingGeneration == null &&
      canVerifyReconnectedServer &&
      state.hostVerified &&
      identical(_verifiedSession, ref.read(dashboardActiveSessionProvider));
  void acknowledgeAfterReconnect() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!canAcknowledge ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    _release();
    _session = null;
    _verifiedSession = null;
    state = const ConfigurationBackupState(
      status: ConfigurationBackupStatus.rejected,
      message: 'Independent inspection acknowledged. The prior backup remains unverified and is not replayed. Reload and review a new export if needed.',
    );
    ref.invalidate(configurationBackupInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
