import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const smbCaps = SmbSharesCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canCreate: true,
  canUpdate: true,
  canDelete: true,
);
SmbShareInventory smbInventory({
  String service = 'RUNNING',
  bool boot = true,
  bool empty = false,
  String? blockedReason,
  bool? locked = false,
}) => SmbShareInventory(
  serviceState: service,
  serviceEnabled: boot,
  datasets: const [
    SmbShareDataset(
      id: 'tank/team',
      guid: '1001',
      mountpoint: '/mnt/tank/team',
    ),
    SmbShareDataset(id: 'tank/new', guid: '1002', mountpoint: '/mnt/tank/new'),
    SmbShareDataset(
      id: 'tank/locked',
      guid: '1003',
      mountpoint: '/mnt/tank/locked',
      blockedReason: 'Locked root',
    ),
  ],
  shares: empty
      ? const []
      : [
          SmbShareEntry(
            id: 4,
            name: 'Team files',
            path: '/mnt/tank/team',
            comment: 'Original comment',
            readonly: false,
            enabled: true,
            purpose: 'DEFAULT_SHARE',
            locked: locked,
            blockedReason: blockedReason,
          ),
          const SmbShareEntry(
            id: 5,
            name: 'Archive',
            path: '/mnt/tank/archive',
            comment: '',
            readonly: true,
            enabled: false,
            purpose: 'TIMEMACHINE_SHARE',
            locked: true,
            blockedReason: 'Special-purpose shares are inspect-only.',
          ),
        ],
);

class SmbFake implements SessionRepository, AuthenticatedSmbSharesSession {
  SmbFake({SmbShareInventory? inventory, this.caps = smbCaps})
    : inventory = inventory ?? smbInventory();
  final SmbShareInventory inventory;
  final SmbSharesCapabilities caps;
  int reads = 0;
  final reviews = <SmbShareRequest>[];
  final writes = <SmbShareReview>[];
  Future<SmbShareInventory> Function()? onLoad;
  Future<SmbShareReview> Function(SmbShareRequest)? onReview;
  Future<SmbShareResult> Function()? onExecute;
  @override
  SmbSharesCapabilities get smbSharesCapabilities => caps;
  @override
  Future<SmbShareInventory> loadSmbShares() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<SmbShareReview> reviewSmbShare(SmbShareRequest request) async {
    reviews.add(request);
    return onReview?.call(request) ??
        SmbShareReview(
          action: request.action,
          target: request.target,
          identity: 'Share identity · GUID 1001',
          changes: [
            'Exact reviewed ${request.action.name} for ${request.target}',
          ],
          warnings: ['SMB configuration reload may affect existing clients.'],
        );
  }

  @override
  Future<SmbShareResult> executeSmbShare(
    SmbShareReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call() ??
        const SmbShareResult(
          SmbShareOutcome.verified,
          'Exact SMB configuration was independently read back.',
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
  }) => throw UnsupportedError('No transport in fixtures.');
}

class SmbHarness {
  SmbHarness({SmbFake? fake}) : api = fake ?? SmbFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final SmbFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String? endpoint = 'wss://sample.example/api/current',
    SmbFake? fake,
  }) => AuthenticatedSession(
    profileId: 'sample',
    repository: fake ?? api,
    availableMethodNames: const {},
    version: '25.10.1',
    endpoint: endpoint,
  );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}

SmbShareReview smbReview({SmbShareAction action = SmbShareAction.update}) =>
    SmbShareReview(
      action: action,
      target: 'Team files',
      identity: 'Issued identity',
      changes: ['Read-only false → true'],
      warnings: [],
    );
