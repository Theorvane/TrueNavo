import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/enclosures/enclosure_inventory.dart';

void main() {
  test('projects documented chassis and slot fields without serials', () {
    final inventory = EnclosureInventory.parse([
      {
        'name': 'iX 4024Sp c205',
        'model': 'M40',
        'controller': true,
        'status': ['OK'],
        'front_slots': 24,
        'rear_slots': 0,
        'internal_slots': 0,
        'elements': {
          'Array Device Slot': {
            '2': {'descriptor': 'slot01', 'status': 'Not installed'},
            '1': {
              'descriptor': 'slot00',
              'status': 'OK',
              'dev': 'sda',
              'model': 'HUH721212AL4200',
              'serial': 'must-not-be-projected',
              'size': 12000138625024,
              'pool_info': {
                'pool_name': 'tank',
                'disk_status': 'ONLINE',
                'vdev_name': 'mirror-0',
                'vdev_type': 'data',
                'disk_read_errors': 2,
                'disk_write_errors': 0,
                'disk_checksum_errors': 1,
              },
            },
          },
        },
      },
    ]);
    final enclosure = inventory.enclosures.single;
    expect(enclosure.controller, isTrue);
    expect(enclosure.frontSlots, 24);
    expect(enclosure.slots.map((s) => s.number), [1, 2]);
    expect(enclosure.slots.first.device, 'sda');
    expect(enclosure.slots.first.pool, 'tank');
    expect(enclosure.slots.first.vdevName, 'mirror-0');
    expect(enclosure.slots.first.vdevType, 'data');
    expect(enclosure.slots.first.readErrors, 2);
    expect(enclosure.slots.first.writeErrors, 0);
    expect(enclosure.slots.first.checksumErrors, 1);
    expect(enclosure.slots.first.healthy, isTrue);
    expect(enclosure.slots.last.occupied, isFalse);
    expect(
      enclosure.slots.first.toString(),
      isNot(contains('must-not-be-projected')),
    );
  });

  test('generic hardware empty inventory and malformed top level', () {
    expect(EnclosureInventory.parse([]).enclosures, isEmpty);
    expect(() => EnclosureInventory.parse({}), throwsFormatException);
  });
}
