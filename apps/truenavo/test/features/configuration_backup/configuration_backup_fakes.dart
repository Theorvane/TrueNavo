import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/configuration_backup/configuration_backup_controller.dart';
import 'package:truenavo/features/configuration_backup/configuration_backup_file.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const backupEndpoint = 'wss://sample.example/api/current';
const backupHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const backupCaps = ConfigurationBackupCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  transferSupported: true,
);
ConfigurationBackupInventory backupInventory({
  String endpoint = backupEndpoint,
  String hostId = backupHost,
  bool fullAdmin = true,
  bool ha = false,
  bool jobs = false,
  String state = 'READY',
}) => ConfigurationBackupInventory(
  endpoint: endpoint,
  hostId: hostId,
  currentVersion: '25.10.1',
  state: state,
  fullAdmin: fullAdmin,
  failoverLicensed: ha,
  conflictingJob: jobs,
);
ConfigurationBackupReview backupReview(
  ConfigurationBackupInventory inventory, {
  bool seed = false,
  bool keys = false,
}) => ConfigurationBackupReview(
  request: ConfigurationBackupRequest(
    inventory: inventory,
    includeSecretSeed: seed,
    includeAuthorizedKeys: keys,
  ),
  endpoint: inventory.endpoint,
  warnings: const [
    'Synthetic export: sensitive configuration, trusted destination only.',
  ],
);

class BackupFake
    implements SessionRepository, AuthenticatedConfigurationBackupSession {
  BackupFake({ConfigurationBackupInventory? inventory, this.caps = backupCaps})
    : inventory = inventory ?? backupInventory();
  ConfigurationBackupInventory inventory;
  ConfigurationBackupCapabilities caps;
  int reads = 0;
  final reviews = <ConfigurationBackupRequest>[],
      exports = <ConfigurationBackupReview>[];
  final artifacts = <ConfigurationBackupArtifact>[];
  final sourceBuffers = <Uint8List>[];
  Future<ConfigurationBackupInventory> Function()? onLoad;
  Future<ConfigurationBackupReview> Function(ConfigurationBackupRequest)?
  onReview;
  Future<ConfigurationBackupResult> Function(ConfigurationBackupReview)?
  onExecute;
  @override
  ConfigurationBackupCapabilities get configurationBackupCapabilities => caps;
  @override
  Future<ConfigurationBackupInventory> loadConfigurationBackup() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<ConfigurationBackupReview> reviewConfigurationBackup(
    ConfigurationBackupRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        ConfigurationBackupReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic export: sensitive configuration, trusted destination only.',
          ],
        );
  }

  ConfigurationBackupResult completed(
    ConfigurationBackupReview review, {
    int? jobId = 80,
    int? size,
    String? filename,
    bool? seed,
    bool? keys,
    bool disposed = false,
  }) {
    final bytes =
        Uint8List(
          size ??
              (review.request.includeSecretSeed ||
                      review.request.includeAuthorizedKeys
                  ? 2048
                  : 512),
        )..fillRange(
          0,
          size ??
              (review.request.includeSecretSeed ||
                      review.request.includeAuthorizedKeys
                  ? 2048
                  : 512),
          102,
        );
    sourceBuffers.add(bytes);
    final artifact = ConfigurationBackupArtifact(
      bytes: bytes,
      filename: filename ?? review.request.filename,
      includesSecretSeed: seed ?? review.request.includeSecretSeed,
      includesAuthorizedKeys: keys ?? review.request.includeAuthorizedKeys,
    );
    artifacts.add(artifact);
    if (disposed) artifact.dispose();
    return ConfigurationBackupResult(
      ConfigurationBackupOutcome.completed,
      'Synthetic validated export.',
      jobId: jobId,
      artifact: artifact,
    );
  }

  @override
  Future<ConfigurationBackupResult> executeConfigurationBackup(
    ConfigurationBackupReview review,
    String confirmation,
  ) async {
    exports.add(review);
    return onExecute?.call(review) ?? completed(review);
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('No connector in backup fixtures.');
}

class BackupSaverFake implements ConfigurationBackupFileSaver {
  BackupSaverFake({this.supported = true});
  @override
  final bool supported;
  int saves = 0, cancellations = 0;
  final filenames = <String>[];
  final received = <Uint8List>[];
  Future<ConfigurationBackupSaveOutcome> Function(Uint8List, bool Function())?
  onSave;
  @override
  Future<ConfigurationBackupSaveOutcome> save({
    required Uint8List bytes,
    required String filename,
    required bool Function() isCurrent,
  }) async {
    saves++;
    filenames.add(filename);
    received.add(bytes);
    // Deliberately do not wipe: controller's finally must protect every saver.
    return onSave?.call(bytes, isCurrent) ??
        (isCurrent()
            ? ConfigurationBackupSaveOutcome.saved
            : ConfigurationBackupSaveOutcome.cancelled);
  }

  @override
  void cancel() {
    cancellations++;
  }
}

class BackupHarness {
  BackupHarness({BackupFake? fake, BackupSaverFake? saver})
    : api = fake ?? BackupFake(),
      saver = saver ?? BackupSaverFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => active),
        configurationBackupFileSaverProvider.overrideWithValue(this.saver),
      ],
    );
  }
  final BackupFake api;
  final BackupSaverFake saver;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = backupEndpoint}) =>
      AuthenticatedSession(
        profileId: 'sample',
        repository: api,
        availableMethodNames: const {},
        version: '25.10.1',
        endpoint: endpoint,
      );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  Future<void> load() =>
      container.read(configurationBackupInventoryProvider.future);
  void dispose() => container.dispose();
}
