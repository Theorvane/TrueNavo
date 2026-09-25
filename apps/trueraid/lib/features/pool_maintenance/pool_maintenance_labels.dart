import 'package:truenas_api/truenas_api.dart';

String poolMaintenanceActionLabel(PoolMaintenanceAction action) =>
    switch (action) {
      PoolMaintenanceAction.startScrub => 'Start scrub',
      PoolMaintenanceAction.stopScrub => 'Stop this scrub',
      PoolMaintenanceAction.createSchedule => 'Create schedule',
      PoolMaintenanceAction.updateSchedule => 'Edit schedule',
      PoolMaintenanceAction.deleteSchedule => 'Delete schedule',
      PoolMaintenanceAction.enableSchedule => 'Enable schedule',
      PoolMaintenanceAction.disableSchedule => 'Disable schedule',
    };
