import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/enclosures/enclosure_inventory.dart';
import 'package:trueraid/features/enclosures/enclosures_page.dart';

void main() {
  testWidgets('shows read-only enclosure slots without serial or controls', (
    tester,
  ) async {
    final inventory = EnclosureInventory.parse([
      {
        'name': 'iX chassis',
        'model': 'M40',
        'controller': true,
        'status': ['OK'],
        'front_slots': 2,
        'elements': {
          'Array Device Slot': {
            '1': {
              'descriptor': 'slot00',
              'status': 'OK',
              'dev': 'sda',
              'serial': 'hidden-serial',
              'size': 1099511627776,
              'pool_info': {
                'pool_name': 'tank',
                'disk_status': 'ONLINE',
                'vdev_name': 'mirror-0',
                'disk_read_errors': 2,
                'disk_write_errors': 0,
                'disk_checksum_errors': 1,
              },
            },
          },
        },
      },
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          enclosureInventoryProvider.overrideWith((ref) async => inventory),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const EnclosuresPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('iX chassis'), findsOneWidget);
    expect(find.text('slot00'), findsOneWidget);
    expect(find.textContaining('tank'), findsOneWidget);
    expect(find.textContaining('hidden-serial'), findsNothing);
    expect(find.textContaining('Identify'), findsNothing);
    final occupancy = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('enclosure-occupancy')),
    );
    expect(occupancy.value, 1);
    await tester.tap(find.byKey(const Key('enclosure-slot-1')));
    await tester.pumpAndSettle();
    expect(find.text('Capacity: 1.0 TiB'), findsOneWidget);
    expect(find.text('Vdev: mirror-0'), findsOneWidget);
    expect(find.text('Read: 2'), findsOneWidget);
    expect(find.text('Write: 0'), findsOneWidget);
    expect(find.text('Checksum: 1'), findsOneWidget);
    expect(find.textContaining('hidden-serial'), findsNothing);
    expect(find.text('Close'), findsOneWidget);
  });
}
