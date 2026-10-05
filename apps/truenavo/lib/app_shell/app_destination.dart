import 'package:flutter/material.dart';

enum AppDestination {
  home('Home', Icons.home_outlined, Icons.home),
  storage('Storage', Icons.storage_outlined, Icons.storage),
  workloads('Workloads', Icons.widgets_outlined, Icons.widgets),
  alerts('Alerts', Icons.notifications_outlined, Icons.notifications),
  jobs('Jobs', Icons.work_outline, Icons.work);

  const AppDestination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
