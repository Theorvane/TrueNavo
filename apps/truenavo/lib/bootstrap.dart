import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/local_persistence/app_database.dart';
import 'features/local_persistence/database_connection.dart';
import 'features/local_persistence/drift_server_profile_store.dart';
import 'features/server_profiles/server_profile_store.dart';
import 'features/server_profiles/server_profiles_controller.dart';
import 'truenavo_app.dart';

typedef OpenServerProfileStore = Future<ServerProfileStore> Function();
typedef RunApplication = FutureOr<void> Function(Widget app);

/// Credential-free startup error. Deliberately contains no database detail.
final class StartupFailure implements Exception {
  const StartupFailure();
  static const message = 'Unable to start local storage safely.';
  @override
  String toString() => message;
}

/// Opens and hydrates persistence before any ProviderScope/TrueNavoApp render.
/// Once handed to the root, that root is the sole lifecycle owner.
Future<void> bootstrapTrueNavo({
  OpenServerProfileStore? openStore,
  RunApplication? run,
}) async {
  ServerProfileStore? store;
  var rootOwnsStore = false;
  try {
    store = await (openStore ?? _openProductionStore)();
    final snapshot = await store.load();
    final app = _StoreOwningRoot(
      store: store,
      snapshot: snapshot,
      onOwnershipAcquired: () => rootOwnsStore = true,
      child: const ProviderScopePlaceholder(),
    );
    final runner = run ?? _runFlutterApp;
    await Future<void>.sync(() => runner(app));
  } catch (_) {
    if (!rootOwnsStore) await _closeSafely(store);
    throw const StartupFailure();
  }
}

Future<ServerProfileStore> _openProductionStore() async =>
    DriftServerProfileStore(AppDatabase(openLocalDatabase()));

void _runFlutterApp(Widget app) => runApp(app);

Future<void> _closeSafely(ServerProfileStore? store) async {
  if (store == null) return;
  try {
    await store.close();
  } catch (_) {
    // Startup failures remain credential-free and stable.
  }
}

final class _StoreOwningRoot extends StatefulWidget {
  const _StoreOwningRoot({
    required this.store,
    required this.snapshot,
    required this.onOwnershipAcquired,
    required this.child,
  });
  final ServerProfileStore store;
  final ServerProfileSnapshot snapshot;
  final VoidCallback onOwnershipAcquired;
  final Widget child;

  @override
  State<_StoreOwningRoot> createState() => _StoreOwningRootState();
}

final class _StoreOwningRootState extends State<_StoreOwningRoot> {
  var _closed = false;

  @override
  void initState() {
    super.initState();
    widget.onOwnershipAcquired();
  }

  @override
  void dispose() {
    _closeOnce();
    super.dispose();
  }

  void _closeOnce() {
    if (_closed) return;
    _closed = true;
    unawaited(_closeSafely(widget.store));
  }

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      serverProfileStoreProvider.overrideWithValue(widget.store),
      initialServerProfileSnapshotProvider.overrideWithValue(widget.snapshot),
    ],
    child: widget.child,
  );
}

/// Avoids constructing the application until the root's scoped overrides exist.
final class ProviderScopePlaceholder extends StatelessWidget {
  const ProviderScopePlaceholder({super.key});
  @override
  Widget build(BuildContext context) => const TrueNavoApp();
}
