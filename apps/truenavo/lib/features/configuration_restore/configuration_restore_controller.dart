import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'configuration_restore_file.dart';

final configurationRestoreSessionProvider =
    Provider<AuthenticatedConfigurationRestoreSession?>((ref) {
      final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repo is AuthenticatedConfigurationRestoreSession
          ? repo as AuthenticatedConfigurationRestoreSession
          : null;
    });
final configurationRestoreInventoryProvider =
    FutureProvider<ConfigurationRestoreInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider),
          api = ref.watch(configurationRestoreSessionProvider);
      if (session?.endpoint == null ||
          api == null ||
          ref.read(configurationRestoreControllerProvider).locked) {
        throw StateError('Restore readiness unavailable.');
      }
      final inventory = await api.loadConfigurationRestore();
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          inventory.endpoint != session!.endpoint) {
        throw StateError('Restore connection changed.');
      }
      return inventory;
    }, retry: (_, _) => null);

final class RestoreFileSummary {
  RestoreFileSummary(ConfigurationRestoreFile file)
    : sha256 = file.sha256,
      byteLength = file.byteLength,
      format = file.format,
      hasSecretSeed = file.hasSecretSeed,
      authorizedKeyMembers = List.unmodifiable(file.authorizedKeyMembers);
  final String sha256;
  final int byteLength;
  final ConfigurationRestoreFormat format;
  final bool hasSecretSeed;
  final List<String> authorizedKeyMembers;
}

enum ConfigurationRestoreStatus {
  idle,
  choosing,
  reading,
  preparing,
  ready,
  reviewing,
  executing,
  accepted,
  rejected,
  unknown,
}

final class ConfigurationRestoreState {
  const ConfigurationRestoreState({
    this.status = ConfigurationRestoreStatus.idle,
    this.message,
    this.selection,
    this.server,
    this.hostId,
    this.jobId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
    this.verifiedEndpoint,
    this.changedAddressAccepted = false,
  });
  final ConfigurationRestoreStatus status;
  final String? message, server, hostId, verificationMessage, verifiedEndpoint;
  final RestoreFileSummary? selection;
  final int? jobId;
  final bool connectionCurrent, verifying, hostVerified, changedAddressAccepted;
  bool get addressChanged =>
      hostVerified && verifiedEndpoint != null && verifiedEndpoint != server;
  bool get busy => const {
    ConfigurationRestoreStatus.choosing,
    ConfigurationRestoreStatus.reading,
    ConfigurationRestoreStatus.preparing,
    ConfigurationRestoreStatus.reviewing,
    ConfigurationRestoreStatus.executing,
  }.contains(status);
  bool get unresolved =>
      status == ConfigurationRestoreStatus.accepted ||
      status == ConfigurationRestoreStatus.unknown;
  bool get locked =>
      status == ConfigurationRestoreStatus.executing || unresolved;
  ConfigurationRestoreState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
    String? endpoint,
    bool addressAccepted = false,
  }) => ConfigurationRestoreState(
    status: status,
    message: this.message,
    selection: selection,
    server: server,
    hostId: hostId,
    jobId: jobId,
    connectionCurrent: connectionCurrent,
    verifying: verifying,
    hostVerified: verified,
    verificationMessage: message,
    verifiedEndpoint: endpoint,
    changedAddressAccepted: addressAccepted,
  );
}

final configurationRestoreControllerProvider =
    NotifierProvider<ConfigurationRestoreController, ConfigurationRestoreState>(
      ConfigurationRestoreController.new,
    );

class ConfigurationRestoreController
    extends Notifier<ConfigurationRestoreState> {
  ConfigurationRestoreFile? _file;
  AuthenticatedSession? _fileSession, _operationSession, _verifiedSession;
  ConfigurationRestoreFilePicker? _picker;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false, _choosing = false;
  final _used = Expando<bool>();
  bool get _active =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  ConfigurationRestoreState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next == AppLifecycleState.resumed) return;
        _verificationGeneration++;
        _verifiedSession = null;
        if (state.verifying || state.hostVerified) {
          state = state.verification(
            message: 'Host verification expired. Verify again explicitly.',
          );
        }
        if (!_choosing && (state.busy || _file != null)) discardSelection();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (identical(a, b)) return;
      _verificationGeneration++;
      _verifiedSession = null;
      discardSelection();
      if (state.unresolved) {
        state = ConfigurationRestoreState(
          status: ConfigurationRestoreStatus.unknown,
          message: 'The connection changed. Independently inspect the original machine. Disconnection does not prove restore or reboot success; no upload is replayed.',
          server: state.server,
          hostId: state.hostId,
          jobId: state.jobId,
          connectionCurrent: identical(_operationSession, b),
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _disposeFile();
      _cancelPicker();
      _release();
    });
    return const ConfigurationRestoreState();
  }

  void _disposeFile() {
    _file?.dispose();
    _file = null;
    _fileSession = null;
  }

  void _cancelPicker() {
    final picker = _picker;
    _picker = null;
    _choosing = false;
    try {
      picker?.cancel();
    } on Object {
      /* Fixed state only. */
    }
  }

  void discardSelection() {
    if (!ref.mounted) return;
    _generation++;
    _disposeFile();
    _cancelPicker();
    if (state.locked || _pending) {
      state = ConfigurationRestoreState(
        status: ConfigurationRestoreStatus.unknown,
        message: 'The restore context expired. Its file was discarded. An upload may have started; inspect the original machine before reconnecting. No request is retried.',
        server: state.server,
        hostId: state.hostId,
        jobId: state.jobId,
        connectionCurrent: state.connectionCurrent,
      );
    } else {
      state = const ConfigurationRestoreState(
        message:
            'No file is retained. Choose and review a trusted backup again.',
      );
    }
  }

  /// Destroy sensitive ownership synchronously on route departure; publish only
  /// after widget teardown so Riverpod is not mutated during a widget build.
  void abandonRoute() {
    if (!ref.mounted) return;
    final generation = ++_generation;
    _disposeFile();
    _cancelPicker();
    final next = state.locked || _pending
        ? ConfigurationRestoreState(
            status: ConfigurationRestoreStatus.unknown,
            message: 'The restore route closed. Its file was discarded; any submitted operation remains unverified. Independently inspect the original machine.',
            server: state.server,
            hostId: state.hostId,
            jobId: state.jobId,
            connectionCurrent: state.connectionCurrent,
          )
        : const ConfigurationRestoreState(
            message: 'The selected file was discarded when its restore route closed.',
          );
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) state = next;
    });
  }

  Future<void> chooseFile({
    required AuthenticatedSession expectedSession,
    required bool sensitiveReadAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    bool routeCurrent() {
      try {
        return isRouteCurrent();
      } on Object {
        return false;
      }
    }

    if (!ref.mounted ||
        state.locked ||
        state.busy ||
        !sensitiveReadAccepted ||
        !routeCurrent() ||
        !_active ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final api = expectedSession.repository,
        picker = ref.read(configurationRestoreFilePickerProvider);
    if (api is! AuthenticatedConfigurationRestoreSession ||
        !(api as AuthenticatedConfigurationRestoreSession)
            .configurationRestoreCapabilities
            .canRestore ||
        !picker.supported) {
      return;
    }
    _disposeFile();
    _cancelPicker();
    final generation = ++_generation;
    _picker = picker;
    _choosing = true;
    state = const ConfigurationRestoreState(
      status: ConfigurationRestoreStatus.choosing,
      message: 'Choose a trusted configuration file. Its name and location will not be shown or retained.',
    );
    Uint8List? bytes;
    ConfigurationRestoreFile? file;
    bool current() =>
        ref.mounted &&
        generation == _generation &&
        identical(expectedSession, ref.read(dashboardActiveSessionProvider)) &&
        routeCurrent() &&
        (_choosing || _active);
    try {
      bytes = await picker.pick(
        isCurrent: current,
        onReadStarted: () {
          _choosing = false;
          if (!current()) {
            discardSelection();
            return;
          }
          state = const ConfigurationRestoreState(
            status: ConfigurationRestoreStatus.reading,
            message:
                'Reading bounded sensitive file contents. Keep the app active.',
          );
        },
      );
      _choosing = false;
      if (!current()) {
        if (ref.mounted && generation == _generation) discardSelection();
        return;
      }
      if (bytes == null) {
        state = const ConfigurationRestoreState(
          message: 'File selection cancelled. No file is retained or uploaded.',
        );
        return;
      }
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        throw StateError('Invalid bounded file.');
      }
      state = const ConfigurationRestoreState(
        status: ConfigurationRestoreStatus.preparing,
        message: 'Inspecting format and fingerprint locally. No file has been uploaded.',
      );
      file = await (api as AuthenticatedConfigurationRestoreSession)
          .prepareConfigurationRestore(bytes);
      if (!current()) {
        if (ref.mounted && generation == _generation) discardSelection();
        return;
      }
      if (file.isDisposed) throw StateError('Discarded file.');
      _file = file;
      _fileSession = expectedSession;
      state = ConfigurationRestoreState(
        status: ConfigurationRestoreStatus.ready,
        selection: RestoreFileSummary(file),
        message: 'Format and fingerprint inspected. Source server, version compatibility and recovery suitability are NOT established.',
      );
      file = null;
    } on Object {
      if (current()) {
        state = const ConfigurationRestoreState(
          status: ConfigurationRestoreStatus.rejected,
          message: 'The selected file could not be safely read or inspected. Details were withheld. No file is retained or uploaded.',
        );
      }
    } finally {
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      file?.dispose();
      if (generation == _generation) {
        _picker = null;
        _choosing = false;
      }
    }
  }

  Future<ConfigurationRestoreReview?> review({
    required AuthenticatedSession expectedSession,
    required ConfigurationRestoreInventory inventory,
    required bool Function() isRouteCurrent,
  }) async {
    bool routeCurrent() {
      try {
        return isRouteCurrent();
      } on Object {
        return false;
      }
    }

    final file = _file;
    if (!routeCurrent() ||
        state.busy ||
        state.locked ||
        file == null ||
        file.isDisposed ||
        !_active ||
        !identical(_fileSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        inventory.endpoint != expectedSession.endpoint ||
        !identical(
          inventory,
          ref.read(configurationRestoreInventoryProvider).asData?.value,
        )) {
      return null;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedConfigurationRestoreSession) return null;
    final generation = _generation;
    state = ConfigurationRestoreState(
      status: ConfigurationRestoreStatus.reviewing,
      selection: state.selection,
      message: 'Reviewing current host readiness. No upload has started.',
    );
    try {
      final request = ConfigurationRestoreRequest(
        inventory: inventory,
        file: file,
      );
      final review = await (api as AuthenticatedConfigurationRestoreSession)
          .reviewConfigurationRestore(request);
      if (ref.mounted && generation == _generation && !routeCurrent()) {
        discardSelection();
        return null;
      }
      if (!ref.mounted ||
          generation != _generation ||
          !_active ||
          !identical(_file, file) ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          )) {
        return null;
      }
      if (!identical(review.request, request) ||
          review.endpoint != expectedSession.endpoint ||
          !identical(
            inventory,
            ref.read(configurationRestoreInventoryProvider).asData?.value,
          )) {
        throw StateError('Stale review.');
      }
      state = ConfigurationRestoreState(
        status: ConfigurationRestoreStatus.ready,
        selection: state.selection,
      );
      return review;
    } on Object {
      if (ref.mounted && generation == _generation) {
        discardSelection();
        state = const ConfigurationRestoreState(
          status: ConfigurationRestoreStatus.rejected,
          message: 'Restore review could not be verified. Details were withheld and the selected file was discarded.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required ConfigurationRestoreReview review,
    required String confirmation,
    required String fileHashConfirmation,
    required bool recoveryAccessAccepted,
    required bool independentBackupAccepted,
    required bool trustedFileAccepted,
    required bool replacementAndRebootAccepted,
    required bool missingMaterialLossAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.locked || _used[review] == true) return;
    final file = _file, api = expectedSession.repository;
    final snapshot = ref.read(configurationRestoreInventoryProvider);
    bool routeCurrent() {
      try {
        return isRouteCurrent();
      } on Object {
        return false;
      }
    }

    if (!_active ||
        !routeCurrent() ||
        !recoveryAccessAccepted ||
        !independentBackupAccepted ||
        !trustedFileAccepted ||
        !replacementAndRebootAccepted ||
        !missingMaterialLossAccepted ||
        file == null ||
        file.isDisposed ||
        !identical(file, review.request.file) ||
        fileHashConfirmation != file.sha256 ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedConfigurationRestoreSession ||
        !(api as AuthenticatedConfigurationRestoreSession)
            .configurationRestoreCapabilities
            .canRestore) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = ConfigurationRestoreState(
        status: ConfigurationRestoreStatus.rejected,
        selection: state.selection,
        message: 'Another operation is unresolved. No upload was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        host = review.request.inventory.hostId;
    state = ConfigurationRestoreState(
      status: ConfigurationRestoreStatus.executing,
      server: server,
      hostId: host,
      message: 'Submitting the reviewed restore. A successful migration schedules an automatic reboot; loss of connection is not completion.',
    );
    bool current() {
      if (ref.mounted && generation == _generation && !routeCurrent()) {
        discardSelection();
        return false;
      }
      if (!ref.mounted ||
          generation != _generation ||
          !_active ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          !identical(_file, file) ||
          file.isDisposed) {
        return false;
      }
      final inventory = ref.read(configurationRestoreInventoryProvider);
      if (inventory.isLoading ||
          !identical(review.request.inventory, inventory.asData?.value)) {
        discardSelection();
        return false;
      }
      return generation == _generation;
    }

    try {
      final result = await (api as AuthenticatedConfigurationRestoreSession)
          .executeConfigurationRestore(
            review,
            confirmation,
            isCurrent: current,
          );
      if (ref.mounted && generation == _generation && !routeCurrent()) {
        discardSelection();
      }
      if (!ref.mounted ||
          generation != _generation ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          )) {
        return;
      }
      final accepted =
          result.outcome == ConfigurationRestoreOutcome.accepted &&
          result.jobId != null &&
          result.jobId! > 0 &&
          result.jobId! <= 9007199254740991;
      final rejected = result.outcome == ConfigurationRestoreOutcome.rejected;
      state = ConfigurationRestoreState(
        status: accepted
            ? ConfigurationRestoreStatus.accepted
            : rejected
            ? ConfigurationRestoreStatus.rejected
            : ConfigurationRestoreStatus.unknown,
        server: server,
        hostId: host,
        jobId: accepted ? result.jobId : null,
        message: accepted
            ? 'Upload job accepted; restore and reboot completion are unverified. Independently inspect the original machine. No polling, retry or automatic reconnect occurs.'
            : rejected
            ? 'The reviewed restore was rejected. No success is claimed. The selected file was discarded; reload before a new review.'
            : 'Restore submission is unverified. It may replace configuration and automatically reboot. Independently inspect the original machine before reconnecting; do not repeat it.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = ConfigurationRestoreState(
          status: ConfigurationRestoreStatus.unknown,
          server: server,
          hostId: host,
          message: 'The restore outcome could not be verified. Details were withheld. Independently inspect the original machine; no upload is replayed.',
        );
      }
    } finally {
      file.dispose();
      if (identical(_file, file)) {
        _file = null;
        _fileSession = null;
      }
      _pending = false;
      if (ref.mounted) {
        if (!state.locked) {
          _release();
        } else {
          state = state.verification(
            verifying: state.verifying,
            verified: state.hostVerified,
            message: state.verificationMessage,
            endpoint: state.verifiedEndpoint,
            addressAccepted: state.changedAddressAccepted,
          );
        }
      }
    }
  }

  bool get canVerifyReconnectedServer {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unresolved &&
        !state.verifying &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        !identical(current, _operationSession);
  }

  Future<void> verifyReconnectedServer() async {
    if (!canVerifyReconnectedServer || !_active) return;
    final session = ref.read(dashboardActiveSessionProvider)!,
        api = ref.read(configurationRestoreSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    ConfigurationRestoreInventory? inventory;
    try {
      inventory = await api.loadConfigurationRestore();
    } on Object {
      /* Public fixed outcome. */
    }
    if (!ref.mounted ||
        generation != _verificationGeneration ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final verified =
        inventory?.hostId == state.hostId &&
        inventory?.endpoint == session.endpoint &&
        inventory?.blockedReason == null;
    _verifiedSession = verified ? session : null;
    state = state.verification(
      verified: verified,
      endpoint: verified ? session.endpoint : null,
      message: verified
          ? 'The claimed permanent host identifier and current readiness match the original machine. This is not remote attestation or proof of restoration. Independently verify ownership, any changed address and recovery state.'
          : 'The reconnected original host could not be verified. Details were withheld; writes remain locked.',
    );
  }

  bool get canAcknowledge =>
      !_pending &&
      canVerifyReconnectedServer &&
      state.hostVerified &&
      (!state.addressChanged || state.changedAddressAccepted) &&
      identical(_verifiedSession, ref.read(dashboardActiveSessionProvider));
  void acknowledgeChangedAddress(bool accepted) {
    if (!_active ||
        !state.hostVerified ||
        !state.addressChanged ||
        !identical(
          _verifiedSession,
          ref.read(dashboardActiveSessionProvider),
        )) {
      return;
    }
    state = state.verification(
      verified: true,
      message: state.verificationMessage,
      endpoint: state.verifiedEndpoint,
      addressAccepted: accepted,
    );
  }

  void acknowledgeAfterReconnect() {
    if (!canAcknowledge || !_active) return;
    _release();
    _operationSession = null;
    _verifiedSession = null;
    state = const ConfigurationRestoreState(
      status: ConfigurationRestoreStatus.rejected,
      message: 'Independent original-server inspection acknowledged. Prior restore remains unverified and is not replayed.',
    );
    ref.invalidate(configurationRestoreInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
