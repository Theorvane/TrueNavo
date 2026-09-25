import 'dart:io';

/// TOFU adapters exist only where a runner registers the native bridge
/// channels: the Apple runners and the Android activity.
bool supportsNativeTofuTrust() =>
    Platform.isIOS || Platform.isMacOS || Platform.isAndroid;
