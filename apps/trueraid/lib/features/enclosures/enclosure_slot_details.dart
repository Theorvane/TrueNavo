import 'package:flutter/material.dart';

import 'enclosure_inventory.dart';

class EnclosureSlotDetails extends StatelessWidget {
  const EnclosureSlotDetails({required this.slot, super.key});
  final EnclosureSlot slot;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${slot.descriptor} · #${slot.number}'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Reported by TrueNAS · read only'),
              const SizedBox(height: 16),
              _Detail(label: 'Slot status', value: slot.status),
              if (slot.occupied) ...[
                _Detail(label: 'Device', value: slot.device),
                if (slot.model.isNotEmpty)
                  _Detail(label: 'Model', value: slot.model),
                if (slot.size case final size?)
                  _Detail(label: 'Capacity', value: formatEnclosureSize(size)),
                if (slot.pool.isNotEmpty)
                  _Detail(label: 'Pool', value: slot.pool),
                if (slot.diskStatus.isNotEmpty)
                  _Detail(label: 'Disk status', value: slot.diskStatus),
                if (slot.vdevName.isNotEmpty)
                  _Detail(label: 'Vdev', value: slot.vdevName),
                if (slot.vdevType.isNotEmpty)
                  _Detail(label: 'Vdev type', value: slot.vdevType),
                if (slot.readErrors != null ||
                    slot.writeErrors != null ||
                    slot.checksumErrors != null) ...[
                  const SizedBox(height: 8),
                  const Text('Reported error counters'),
                  if (slot.readErrors case final errors?)
                    _Detail(label: 'Read', value: '$errors'),
                  if (slot.writeErrors case final errors?)
                    _Detail(label: 'Write', value: '$errors'),
                  if (slot.checksumErrors case final errors?)
                    _Detail(label: 'Checksum', value: '$errors'),
                ],
              ] else
                const Text('No disk is mapped to this slot.'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text('$label: $value'),
  );
}

String formatEnclosureSize(int bytes) {
  if (bytes < 0) return 'Unknown';
  const unit = 1024;
  if (bytes >= unit * unit * unit * unit) {
    return '${(bytes / (unit * unit * unit * unit)).toStringAsFixed(1)} TiB';
  }
  if (bytes >= unit * unit * unit) {
    return '${(bytes / (unit * unit * unit)).toStringAsFixed(1)} GiB';
  }
  if (bytes >= unit * unit) {
    return '${(bytes / (unit * unit)).toStringAsFixed(1)} MiB';
  }
  return '$bytes B';
}
