import 'dart:io';

import 'package:truedash/features/tls_trust/native_pin_storage_lock.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) exitCode = 64;
  if (exitCode != 0) return;

  final directory = Directory(arguments[0]);
  final role = arguments[1];
  final lock = NativePinStorageLock.forDirectory(directory);
  await lock.withKeys(
    <String>['com.truedash.tls-pin.v1.active.authority'],
    () async {
      final state = File(
        '${directory.path}${Platform.pathSeparator}guarded-state',
      );
      if (role == 'first') {
        await state.writeAsString('first-read');
        await File('${directory.path}${Platform.pathSeparator}first-entered')
            .create();
        final release = File(
          '${directory.path}${Platform.pathSeparator}release',
        );
        while (!await release.exists()) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await state.writeAsString('first-mutated');
        return;
      }
      if (await state.readAsString() != 'first-mutated') exitCode = 65;
      await File('${directory.path}${Platform.pathSeparator}second-mutated')
          .create();
    },
  );
}
