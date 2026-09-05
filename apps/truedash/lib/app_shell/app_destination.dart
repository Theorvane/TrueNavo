import 'package:flutter/material.dart';

enum AppDestination {
  home('Home', Icons.home_outlined, Icons.home),
  alerts('Alerts', Icons.notifications_outlined, Icons.notifications),
  manage('Manage', Icons.tune_outlined, Icons.tune),
  jobs('Jobs', Icons.work_outline, Icons.work);

  const AppDestination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
