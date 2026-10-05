import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'dashboard_layout_store.dart';

DashboardLayoutStore createDashboardLayoutStore() => FileDashboardLayoutStore(
  directory: () async => Directory(
    '${(await getApplicationSupportDirectory()).path}/dashboard-layouts',
  ),
);

/// One bounded, atomic JSON file per hashed profile/endpoint identity. The
/// store never opens profile databases or credential vaults.
final class FileDashboardLayoutStore implements DashboardLayoutStore {
  FileDashboardLayoutStore({required this.directory});
  final Future<Directory> Function() directory;
  Future<void> _serial = Future.value();

  Future<T> _withLease<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  void _validateKey(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError('Invalid layout key.');
    }
  }

  @override
  Future<String?> read(String key) => _withLease(() async {
    _validateKey(key);
    final location = await directory();
    final file = File('${location.path}/$key.json');
    if (!await file.exists()) return null;
    final handle = await file.open();
    try {
      final bytes = await handle.read(8193);
      if (bytes.length > 8192) {
        throw const FormatException('Layout is too large.');
      }
      return utf8.decode(bytes);
    } finally {
      await handle.close();
    }
  });

  @override
  Future<void> write(String key, String value) => _withLease(() async {
    _validateKey(key);
    if (utf8.encode(value).length > 8192) {
      throw const FormatException('Layout is too large.');
    }
    final location = await directory();
    await location.create(recursive: true);
    final temporary = File('${location.path}/$key.pending');
    await temporary.writeAsString(value, flush: true);
    await temporary.rename('${location.path}/$key.json');
  });
}
