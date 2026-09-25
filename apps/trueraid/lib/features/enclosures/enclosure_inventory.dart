// Read-only projection of the documented webui.enclosure.dashboard response.

final class EnclosureInventory {
  const EnclosureInventory(this.enclosures);
  final List<EnclosureSnapshot> enclosures;

  factory EnclosureInventory.parse(Object? value) {
    if (value is! List) {
      throw const FormatException('Invalid enclosure inventory');
    }
    return EnclosureInventory([
      for (final item in value.take(100))
        if (item is Map) EnclosureSnapshot.parse(item),
    ]);
  }
}

final class EnclosureSnapshot {
  const EnclosureSnapshot({
    required this.name,
    required this.model,
    required this.controller,
    required this.status,
    required this.frontSlots,
    required this.rearSlots,
    required this.internalSlots,
    required this.slots,
  });
  final String name, model, status;
  final bool controller;
  final int frontSlots, rearSlots, internalSlots;
  final List<EnclosureSlot> slots;

  factory EnclosureSnapshot.parse(Map data) {
    final rawElements = data['elements'];
    final rawSlots = rawElements is Map
        ? rawElements['Array Device Slot']
        : null;
    final slots = <EnclosureSlot>[];
    if (rawSlots is Map) {
      for (final entry in rawSlots.entries.take(256)) {
        final number = int.tryParse(entry.key.toString());
        if (number == null || number < 0 || entry.value is! Map) continue;
        slots.add(EnclosureSlot.parse(number, entry.value as Map));
      }
    }
    slots.sort((a, b) => a.number.compareTo(b.number));
    final rawStatus = data['status'];
    final status = rawStatus is List
        ? rawStatus.whereType<String>().take(3).join(', ')
        : _label(rawStatus);
    return EnclosureSnapshot(
      name: _label(data['name'], fallback: 'Unnamed enclosure'),
      model: _label(data['model']),
      controller: data['controller'] == true,
      status: status,
      frontSlots: _count(data['front_slots']),
      rearSlots: _count(data['rear_slots']),
      internalSlots: _count(data['internal_slots']),
      slots: List.unmodifiable(slots),
    );
  }
}

final class EnclosureSlot {
  const EnclosureSlot({
    required this.number,
    required this.descriptor,
    required this.status,
    required this.device,
    required this.model,
    required this.size,
    required this.pool,
    required this.diskStatus,
    required this.vdevName,
    required this.vdevType,
    required this.readErrors,
    required this.writeErrors,
    required this.checksumErrors,
  });
  final int number;
  final String descriptor,
      status,
      device,
      model,
      pool,
      diskStatus,
      vdevName,
      vdevType;
  final int? size;
  final int? readErrors, writeErrors, checksumErrors;

  bool get occupied => device.isNotEmpty;
  bool get healthy =>
      status.toUpperCase() == 'OK' &&
      (diskStatus.isEmpty || diskStatus.toUpperCase() == 'ONLINE');

  factory EnclosureSlot.parse(int number, Map data) {
    final poolInfo = data['pool_info'];
    final pool = poolInfo is Map ? poolInfo : const {};
    final rawSize = data['size'];
    return EnclosureSlot(
      number: number,
      descriptor: _label(data['descriptor'], fallback: 'Slot $number'),
      status: _label(data['status']),
      device: _label(data['dev'], fallback: ''),
      model: _label(data['model'], fallback: ''),
      size: rawSize is int && rawSize >= 0 ? rawSize : null,
      pool: _label(pool['pool_name'], fallback: ''),
      diskStatus: _label(pool['disk_status'], fallback: ''),
      vdevName: _label(pool['vdev_name'], fallback: ''),
      vdevType: _label(pool['vdev_type'], fallback: ''),
      readErrors: _nonNegativeInt(pool['disk_read_errors']),
      writeErrors: _nonNegativeInt(pool['disk_write_errors']),
      checksumErrors: _nonNegativeInt(pool['disk_checksum_errors']),
    );
  }
}

int _count(Object? value) =>
    value is int && value >= 0 && value <= 256 ? value : 0;

int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

String _label(Object? value, {String fallback = 'Unknown'}) {
  if (value is! String || value.trim().isEmpty) return fallback;
  final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  return clean.isEmpty
      ? fallback
      : clean.length <= 80
      ? clean
      : clean.substring(0, 80);
}
