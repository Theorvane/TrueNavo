import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final nvmeHostKeyGenerateCoordinatorProvider =
    Provider.autoDispose<NvmeHostKeyGenerateCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostKeyGenerationSession) {
        return null;
      }
      final coordinator = NvmeHostKeyGenerateCoordinator(
        session: session!,
        api: repository as AuthenticatedNvmeHostKeyGenerationSession,
        catalog: (repository as AuthenticatedAdminSession).adminCatalog,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            ref.mounted &&
            identical(session, ref.read(dashboardActiveSessionProvider)),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

/// Owns the opaque envelope; never queries or changes a host configuration.
final class NvmeHostKeyGenerateCoordinator {
  NvmeHostKeyGenerateCoordinator({
    required this.session,
    required this.api,
    required this.catalog,
    required this.lock,
    required this.isCurrent,
  });
  final AuthenticatedSession session;
  final AuthenticatedNvmeHostKeyGenerationSession api;
  final AdminCatalog catalog;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  NvmeGeneratedHostKey? _key;
  bool _closed = false, _busy = false;
  int _epoch = 0;
  bool get hasKey => _key != null && !_key!.isDisposed;
  bool get available =>
      !_closed &&
      session.endpoint != null &&
      catalog.versionSupported &&
      catalog.method('nvmet.host.generate_key') != null &&
      catalog.method('nvmet.host.dhchap_hash_choices')?.supported == true;
  String get confirmation => 'GENERATE NVME KEY';

  void cancel() {
    _epoch++;
    _key?.dispose();
    _key = null;
  }

  void dispose() {
    _closed = true;
    cancel();
  }

  Future<void> generate({
    required String hash,
    required String? nqn,
    required bool generationConsent,
    required bool exposureRiskConsent,
    required String phrase,
  }) async {
    if (!available ||
        !isCurrent() ||
        _busy ||
        !generationConsent ||
        !exposureRiskConsent ||
        phrase != confirmation ||
        !const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(hash) ||
        (nqn != null && !isSupportedNvmeHostNqn(nqn))) {
      throw const NvmeHostKeyGenerationException();
    }
    final owner = lock.acquire();
    if (owner == null) throw const NvmeHostKeyGenerationException();
    cancel();
    final epoch = _epoch;
    _busy = true;
    NvmeGeneratedHostKey? key;
    try {
      key = await api.generateNvmeHostKey(hash: hash, nqn: nqn);
      if (_closed || !isCurrent() || epoch != _epoch || key.isDisposed) {
        throw const NvmeHostKeyGenerationException();
      }
      _key = key;
      key = null;
    } on Object {
      throw const NvmeHostKeyGenerationException();
    } finally {
      key?.dispose();
      _busy = false;
      lock.release(owner);
    }
  }

  String takeForTransfer({required bool exposureConsent}) {
    if (!available || !isCurrent()) {
      cancel();
      throw const NvmeHostKeyGenerationException();
    }
    final key = _key;
    if (key == null || !exposureConsent) {
      throw const NvmeHostKeyGenerationException();
    }
    try {
      return key.takeForTransfer(acknowledgeSecretExposure: true);
    } finally {
      cancel();
    }
  }
}
