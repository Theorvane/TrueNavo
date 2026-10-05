import 'dart:io';

// Run from apps/truenavo. Icon generation is a mechanical size/format conversion
// of the approved master, not a new design or a signing/configuration change.
Future<void> main() async {
  final project = File('ios/Runner.xcodeproj/project.pbxproj');
  final originalProject = project.readAsStringSync();
  try {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'flutter_launcher_icons',
    ]);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    exitCode = result.exitCode;
  } finally {
    // 0.14.4's broad asset-setting replacement also changes the boolean Swift
    // asset-symbol setting to "AppIcon". Our catalog is already named AppIcon;
    // keep the project settings exactly as they were before regenerating assets.
    project.writeAsStringSync(originalProject);
  }
}
