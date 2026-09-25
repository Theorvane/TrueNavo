import 'package:flutter/widgets.dart';

import 'bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await bootstrapTrueRAID();
  } on StartupFailure {
    runApp(const _StartupFailureApp());
  }
}

final class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp();
  @override
  Widget build(BuildContext context) => const Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: Text(StartupFailure.message)),
  );
}
