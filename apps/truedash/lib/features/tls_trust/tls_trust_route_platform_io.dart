import 'dart:io';

/// TOFU adapters currently exist only for Apple native platforms.
bool supportsNativeTofuTrust() => Platform.isIOS || Platform.isMacOS;
