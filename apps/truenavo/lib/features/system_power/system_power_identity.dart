import 'package:flutter/material.dart';
import 'package:truenas_api/truenas_api.dart';

String systemPowerLabel(SystemPowerAction action) => switch (action) {
  SystemPowerAction.reboot => 'Restart server',
  SystemPowerAction.shutdown => 'Shut down server',
};

/// Last-read public identity and explicit readiness facts, not a health score.
class SystemPowerIdentity extends StatelessWidget {
  const SystemPowerIdentity({required this.inventory, super.key});
  final SystemPowerInventory inventory;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Version: ${inventory.currentVersion}'),
      Text('System state: ${inventory.state}'),
      Text(
        'HA licensed: ${inventory.failoverLicensed ? 'Yes — coordinated workflow required' : 'No'}',
      ),
      Text(
        'Active or waiting jobs: ${inventory.conflictingJob ? 'Present — blocked' : 'None in last read'}',
      ),
      Text('Boot pool: ${inventory.bootPool}'),
      Text(
        'Boot pool readiness: ${inventory.bootHealthy ? 'Healthy, online and not scanning in last read' : 'Not ready or unverified'}',
      ),
      Text(
        'Running environment: ${inventory.currentEnvironment?.id ?? 'Unverified'}',
      ),
      Text(
        'Next-boot environment: ${inventory.nextEnvironment?.id ?? 'Unverified'}',
      ),
      const SizedBox(height: 12),
      const Text('Full public host identity'),
      SelectableText(inventory.hostId),
      const Text('Current boot identity'),
      SelectableText(inventory.bootId),
      if (inventory.rebootReasonCodes.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('Server-reported reboot reason codes'),
        for (final code in inventory.rebootReasonCodes) Text(code),
      ],
    ],
  );
}
