import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/configuration_restore/configuration_restore_controller.dart';
import 'package:truenavo/features/configuration_restore/configuration_restore_file.dart';
import 'package:truenas_api/truenas_api.dart';

const restoreEndpoint = 'wss://sample.example/api/current';
const restoreHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const restoreCaps = ConfigurationRestoreCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  transferSupported: true,
);
Uint8List restoreBytes({int marker = 7}) {
  final bytes = Uint8List(512);
  bytes.setRange(0, 16, [
    83,
    81,
    76,
    105,
    116,
    101,
    32,
    102,
    111,
    114,
    109,
    97,
    116,
    32,
    51,
    0,
  ]);
  bytes[16] = 2;
  bytes[18] = 1;
  bytes[19] = 1;
  bytes[100] = marker;
  return bytes;
}

ConfigurationRestoreInventory restoreInventory({
  String endpoint = restoreEndpoint,
  String hostId = restoreHost,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool nextChanged = false,
}) => ConfigurationRestoreInventory(
  endpoint: endpoint,
  hostId: hostId,
  bootId: '12345678-1234-4234-8234-123456789abc',
  currentVersion: '25.10.1',
  state: state,
  fullAdmin: admin,
  failoverLicensed: ha,
  conflictingJob: jobs,
  bootPool: 'boot-pool',
  bootHealthy: healthy,
  environments: [
    BootEnvironmentSnapshot(
      id: '25.10.1',
      dataset: 'boot-pool/ROOT/25.10.1',
      created: '2026-09-01T10:00:00',
      usedBytes: 512,
      active: true,
      activated: !nextChanged,
      keep: true,
      canActivate: true,
    ),
    if (nextChanged)
      const BootEnvironmentSnapshot(
        id: '25.10.2',
        dataset: 'boot-pool/ROOT/25.10.2',
        created: '2026-09-10T10:00:00',
        usedBytes: 512,
        active: false,
        activated: true,
        keep: true,
        canActivate: true,
      ),
  ],
);

class RestoreFake
    implements SessionRepository, AuthenticatedConfigurationRestoreSession {
  RestoreFake({
    ConfigurationRestoreInventory? inventory,
    this.caps = restoreCaps,
  }) : inventory = inventory ?? restoreInventory();
  ConfigurationRestoreInventory inventory;
  ConfigurationRestoreCapabilities caps;
  int reads = 0, uploads = 0;
  final files = <ConfigurationRestoreFile>[],
      prepared = <Uint8List>[],
      reviews = <ConfigurationRestoreRequest>[],
      executes = <ConfigurationRestoreReview>[];
  Future<ConfigurationRestoreInventory> Function()? onLoad;
  Future<ConfigurationRestoreFile> Function(Uint8List)? onPrepare;
  Future<ConfigurationRestoreReview> Function(ConfigurationRestoreRequest)?
  onReview;
  Future<ConfigurationRestoreResult> Function(
    ConfigurationRestoreReview,
    bool Function(),
  )?
  onExecute;
  @override
  ConfigurationRestoreCapabilities get configurationRestoreCapabilities => caps;
  @override
  Future<ConfigurationRestoreInventory> loadConfigurationRestore() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<ConfigurationRestoreFile> prepareConfigurationRestore(
    Uint8List bytes,
  ) async {
    prepared.add(bytes);
    final file =
        await (onPrepare?.call(bytes) ??
            Future.value(ConfigurationRestoreFile.fromBytes(bytes)));
    files.add(file);
    return file;
  }

  @override
  Future<ConfigurationRestoreReview> reviewConfigurationRestore(
    ConfigurationRestoreRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        ConfigurationRestoreReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic review. Configuration replacement triggers automatic reboot.',
          ],
        );
  }

  @override
  Future<ConfigurationRestoreResult> executeConfigurationRestore(
    ConfigurationRestoreReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    if (onExecute != null) return onExecute!(review, isCurrent);
    if (isCurrent()) uploads++;
    return const ConfigurationRestoreResult(
      ConfigurationRestoreOutcome.rejected,
      'Synthetic rejection. No real upload.',
    );
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
  }) => throw UnsupportedError('No connector in restore fixtures.');
}

class RestorePickerFake implements ConfigurationRestoreFilePicker {
  RestorePickerFake({this.supported = true});
  @override
  final bool supported;
  int picks = 0, cancellations = 0;
  final delivered = <Uint8List>[];
  Future<Uint8List?> Function(bool Function(), void Function()?)? onPick;
  @override
  Future<Uint8List?> pick({
    required bool Function() isCurrent,
    void Function()? onReadStarted,
  }) async {
    picks++;
    if (onPick != null) return onPick!(isCurrent, onReadStarted);
    onReadStarted?.call();
    final bytes = restoreBytes();
    delivered.add(bytes);
    return bytes;
  }

  @override
  void cancel() {
    cancellations++;
  }
}

class RestoreHarness {
  RestoreHarness({RestoreFake? fake, RestorePickerFake? picker})
    : api = fake ?? RestoreFake(),
      picker = picker ?? RestorePickerFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => active),
        configurationRestoreFilePickerProvider.overrideWithValue(this.picker),
      ],
    );
  }
  final RestoreFake api;
  final RestorePickerFake picker;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = restoreEndpoint}) =>
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
      container.read(configurationRestoreInventoryProvider.future);
  void dispose() => container.dispose();
}
