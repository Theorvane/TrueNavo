import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

NfsShareInventory nfsInventory({String? blockedReason}) => NfsShareInventory(
  shares: [
    NfsShare(
      id: 4,
      settings: NfsShareSettings(
        path: '/mnt/tank/media',
        comment: 'Media export',
        networks: ['192.168.10.0/24'],
      ),
    ),
    NfsShare(
      id: 5,
      settings: NfsShareSettings(
        path: '/mnt/tank/archive',
        enabled: false,
        readOnly: true,
      ),
    ),
  ],
  datasets: const [
    NfsShareDataset(id: 'tank/media', guid: '100', path: '/mnt/tank/media'),
    NfsShareDataset(id: 'tank/archive', guid: '101', path: '/mnt/tank/archive'),
    NfsShareDataset(id: 'tank/new', guid: '102', path: '/mnt/tank/new'),
  ],
  serviceState: 'RUNNING',
  serviceEnabled: true,
  protocols: ['NFSV3', 'NFSV4'],
  blockedReason: blockedReason,
);

class NfsFake implements SessionRepository, AuthenticatedNfsSharesSession {
  NfsFake({NfsShareInventory? inventory, this.writable = true})
    : inventory = inventory ?? nfsInventory();
  final NfsShareInventory inventory;
  final bool writable;
  int reads = 0;
  final reviews = <NfsShareRequest>[], writes = <NfsShareReview>[];
  Future<NfsShareInventory> Function()? onLoad;
  Future<NfsShareReview> Function(NfsShareRequest)? onReview;
  Future<NfsShareResult> Function()? onExecute;
  @override
  NfsSharesCapabilities get nfsSharesCapabilities => NfsSharesCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
    canCreate: writable,
    canUpdate: writable,
    canDelete: writable,
  );
  @override
  Future<NfsShareInventory> loadNfsShares() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<NfsShareReview> reviewNfsShare(NfsShareRequest request) async {
    reviews.add(request);
    return onReview?.call(request) ??
        NfsShareReview(
          action: request.action,
          target: request.target,
          identity: 'tank/media · GUID 100',
          changes: ['Exact reviewed ${request.action.name}'],
          warnings: [
            'NFS exports reload globally. Existing clients and pending I/O can be affected.',
            'Manual /etc/exports.d configurations must be absent. No ownership or ACL rewrite.',
          ],
        );
  }

  @override
  Future<NfsShareResult> executeNfsShare(
    NfsShareReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call() ??
        const NfsShareResult(
          NfsShareOutcome.verified,
          'Exact configuration read back; client access not proven.',
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

class NfsHarness {
  NfsHarness({NfsFake? fake}) : api = fake ?? NfsFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final NfsFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String? endpoint = 'wss://sample.example/api/current',
    NfsFake? fake,
  }) => AuthenticatedSession(
    profileId: 'sample',
    repository: fake ?? api,
    availableMethodNames: const {
      'sharing.nfs.query',
      'sharing.nfs.create',
      'sharing.nfs.update',
      'sharing.nfs.delete',
    },
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

NfsShareReview nfsReview() => NfsShareReview(
  action: NfsShareAction.update,
  target: 'NFS #4: /mnt/tank/media',
  identity: 'GUID 100',
  changes: ['Read only: false → true'],
  warnings: ['Global NFS export reload'],
);
