import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Future<void> main() async {
  final manifestFile = File('web/drift-assets.json');
  final manifest = jsonDecode(await manifestFile.readAsString());
  if (manifest is! Map<String, Object?> || manifest['assets'] is! Map) {
    throw const FormatException('Invalid Drift Web asset manifest.');
  }

  final assets = manifest['assets']! as Map;
  for (final entry in assets.entries) {
    final name = entry.key;
    final metadata = entry.value;
    if (name is! String || metadata is! Map) {
      throw const FormatException('Invalid Drift Web asset entry.');
    }
    final file = File('web/$name');
    final bytes = await file.readAsBytes();
    final expectedBytes = metadata['bytes'];
    final expectedSha256 = metadata['sha256'];
    if (expectedBytes is! int || expectedSha256 is! String) {
      throw const FormatException('Invalid Drift Web asset metadata.');
    }
    if (bytes.length != expectedBytes || sha256.convert(bytes).toString() != expectedSha256) {
      throw StateError('Drift Web asset integrity check failed: $name');
    }
  }
}
