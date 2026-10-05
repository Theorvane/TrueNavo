import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

enum ShareProtocol {
  smb('SMB'),
  nfs('NFS');

  const ShareProtocol(this.label);
  final String label;
}

final class SharedPathEntry {
  const SharedPathEntry({
    required this.protocol,
    required this.id,
    required this.name,
    required this.path,
    required this.enabled,
    required this.readOnly,
    this.locked,
    this.restriction,
    this.dataset,
  });
  final ShareProtocol protocol;
  final int id;
  final String name, path;
  final bool enabled, readOnly;
  final bool? locked;
  final String? restriction, dataset;
  String get identity => '${protocol.name}:$id';
  bool matches(String filter) =>
      '${protocol.label} $id $name $path ${dataset ?? ''}'
          .toLowerCase()
          .contains(filter.toLowerCase().trim());
}

final class ShareProtocolOverview {
  ShareProtocolOverview({
    required this.protocol,
    required List<SharedPathEntry> shares,
    this.serviceState,
    this.autostart,
    this.unavailable,
    this.restriction,
  }) : shares = List.unmodifiable(shares);
  final ShareProtocol protocol;
  final List<SharedPathEntry> shares;
  final String? serviceState, unavailable, restriction;
  final bool? autostart;
  bool get loaded => unavailable == null;
  int get enabled => shares.where((s) => s.enabled).length;
  int get readOnly => shares.where((s) => s.readOnly).length;
  bool needsAttention(SharedPathEntry entry) =>
      entry.enabled && serviceState != 'RUNNING' ||
      entry.locked == true ||
      entry.restriction != null ||
      restriction != null;
}

final class SharesOverview {
  SharesOverview({
    required this.endpoint,
    required this.observedAt,
    required List<ShareProtocolOverview> protocols,
  }) : protocols = List.unmodifiable(protocols);
  final String endpoint;
  final DateTime observedAt;
  final List<ShareProtocolOverview> protocols;
  List<SharedPathEntry> get shares =>
      List.unmodifiable(protocols.expand((p) => p.shares));
  int get loadedSources => protocols.where((p) => p.loaded).length;
  int get enabled => shares.where((s) => s.enabled).length;
  int get disabled => shares.length - enabled;

  /// Exact string matches only: no symlink, bind mount or path-alias inference.
  Map<String, List<SharedPathEntry>> get paths {
    final groups = <String, List<SharedPathEntry>>{};
    for (final s in shares) {
      groups.putIfAbsent(s.path, () => []).add(s);
    }
    return Map.unmodifiable(
      groups.map(
        (path, entries) =>
            MapEntry(path, List<SharedPathEntry>.unmodifiable(entries)),
      ),
    );
  }
}

Future<SharesOverview> loadSharesOverview({
  required SessionRepository repository,
  required String endpoint,
  required bool Function() isCurrent,
  DateTime Function()? now,
}) async {
  void check() {
    if (!isCurrent()) {
      throw StateError('The connection changed.');
    }
  }

  final sources = <ShareProtocolOverview>[];
  Future<void> read(
    ShareProtocol protocol,
    Future<ShareProtocolOverview> Function()? loader,
  ) async {
    check();
    if (loader == null) {
      sources.add(
        ShareProtocolOverview(
          protocol: protocol,
          shares: const [],
          unavailable: 'The native inventory is unavailable. Counts are unknown, not zero.',
        ),
      );
      return;
    }
    try {
      final result = await loader();
      check();
      sources.add(result);
    } on Object {
      check();
      sources.add(
        ShareProtocolOverview(
          protocol: protocol,
          shares: const [],
          unavailable: 'This inventory could not be read safely. Counts are unknown, not zero. Refresh explicitly to try again.',
        ),
      );
    }
  }

  await read(
    ShareProtocol.smb,
    repository is AuthenticatedSmbSharesSession
        ? () async {
            final i = await (repository as AuthenticatedSmbSharesSession)
                .loadSmbShares();
            return ShareProtocolOverview(
              protocol: ShareProtocol.smb,
              serviceState: i.serviceState,
              autostart: i.serviceEnabled,
              shares: [
                for (final s in i.shares)
                  SharedPathEntry(
                    protocol: ShareProtocol.smb,
                    id: s.id,
                    name: s.name,
                    path: s.path,
                    enabled: s.enabled,
                    readOnly: s.readonly,
                    locked: s.locked,
                    restriction: s.blockedReason,
                    dataset: _uniqueDataset(
                      i.datasets
                          .where((d) => d.mountpoint == s.path)
                          .map((d) => d.id),
                    ),
                  ),
              ],
            );
          }
        : null,
  );
  await read(
    ShareProtocol.nfs,
    repository is AuthenticatedNfsSharesSession
        ? () async {
            final i = await (repository as AuthenticatedNfsSharesSession)
                .loadNfsShares();
            return ShareProtocolOverview(
              protocol: ShareProtocol.nfs,
              serviceState: i.serviceState,
              autostart: i.serviceEnabled,
              restriction: i.blockedReason,
              shares: [
                for (final s in i.shares)
                  SharedPathEntry(
                    protocol: ShareProtocol.nfs,
                    id: s.id,
                    name: s.settings.comment.isEmpty
                        ? 'NFS export #${s.id}'
                        : s.settings.comment,
                    path: s.settings.path,
                    enabled: s.settings.enabled,
                    readOnly: s.settings.readOnly,
                    restriction: s.blockedReason,
                    dataset: _uniqueDataset(
                      i.datasets
                          .where((d) => d.path == s.settings.path)
                          .map((d) => d.id),
                    ),
                  ),
              ],
            );
          }
        : null,
  );
  check();
  return SharesOverview(
    endpoint: endpoint,
    observedAt: (now ?? DateTime.now)().toUtc(),
    protocols: sources,
  );
}

String? _uniqueDataset(Iterable<String> ids) {
  final unique = ids.toSet();
  return unique.length == 1 ? unique.single : null;
}

final sharesOverviewProvider = FutureProvider.autoDispose<SharesOverview>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  if (session?.endpoint == null) {
    throw StateError('Connect before inspecting shares.');
  }
  var current = true;
  ref.onDispose(() => current = false);
  final lock = ref.read(serverOperationLockProvider);
  final owner = lock.acquire();
  if (owner == null) {
    throw StateError('Another operation is pending.');
  }
  try {
    return await loadSharesOverview(
      repository: session!.repository,
      endpoint: session.endpoint!,
      isCurrent: () =>
          current &&
          identical(session, ref.read(dashboardActiveSessionProvider)),
    );
  } finally {
    lock.release(owner);
  }
}, retry: (_, _) => null);
