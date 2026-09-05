import 'package:flutter/material.dart';

import 'features/connection/connection_screen.dart';

class TrueDashApp extends StatelessWidget {
  const TrueDashApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TrueDash',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff3d6bea),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff0c1020),
    ),
    home: const ConnectionScreen(),
  );
}
