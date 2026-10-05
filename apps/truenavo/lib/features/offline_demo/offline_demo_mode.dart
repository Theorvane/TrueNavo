import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Explicit presentation marker only. This never grants a live capability.
final offlineDemoModeProvider = Provider<bool>((ref) => false);
