import 'package:truenas_api/truenas_api.dart';

String rsyncActionLabel(RsyncAction action) => switch (action) {
  RsyncAction.create => 'Create disabled task',
  RsyncAction.update => 'Edit disabled task',
  RsyncAction.enable => 'Enable scheduled transfers',
  RsyncAction.disable => 'Disable scheduled transfers',
  RsyncAction.delete => 'Delete task configuration',
  RsyncAction.run => 'Run transfer once',
};
