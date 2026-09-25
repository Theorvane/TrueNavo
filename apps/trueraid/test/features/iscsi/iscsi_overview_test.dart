import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';

void main() {
  test(
    'projects target extent and LUN identities without sensitive fields',
    () {
      final overview = IscsiOverview.parse(
        portals: [
          {
            'id': 3,
            'listen': [
              {'ip': '192.0.2.10', 'port': 3260},
            ],
          },
        ],
        initiators: [
          {
            'id': 6,
            'initiators': ['iqn.example:client'],
          },
        ],
        targets: [
          {
            'id': 4,
            'name': 'iqn.example:tank',
            'mode': 'ISCSI',
            'groups': [
              {'portal': 3, 'initiator': 6, 'authmethod': 'CHAP', 'auth': 7},
            ],
          },
        ],
        extents: [
          {
            'id': 8,
            'name': 'volume-1',
            'type': 'DISK',
            'enabled': true,
            'ro': false,
            'locked': false,
            'path': '/mnt/private/volume',
            'serial': 'secret-serial',
          },
        ],
        mappings: [
          {'id': 10, 'target': 4, 'extent': 8, 'lunid': 2},
        ],
      );
      expect(overview.targetById(4)?.name, 'iqn.example:tank');
      expect(overview.portalById(3)?.listeners.single.port, 3260);
      expect(overview.initiatorById(6)?.names.single, 'iqn.example:client');
      expect(overview.targetById(4)?.groups.single.portalId, 3);
      expect(overview.targetById(4)?.groups.single.initiatorId, 6);
      expect(overview.targetById(4)?.groups.single.authMethod, 'CHAP');
      expect(overview.targetById(4)?.toString(), isNot(contains('auth: 7')));
      expect(overview.extentById(8)?.enabled, true);
      expect(overview.mappings.single.lun, 2);
      expect(overview.toString(), isNot(contains('secret-serial')));
      expect(
        overview.extents.single.toString(),
        isNot(contains('/mnt/private')),
      );
    },
  );

  test(
    'rejects incomplete and duplicate inventories instead of partial counts',
    () {
      expect(
        () => IscsiOverview.parse(
          portals: [],
          initiators: [],
          targets: [
            {'id': 1, 'name': 'one'},
            {'id': 1, 'name': 'two'},
          ],
          extents: [],
          mappings: [],
        ),
        throwsFormatException,
      );
      expect(
        () => IscsiOverview.parse(
          portals: [],
          initiators: [],
          targets: ['[additional items omitted]'],
          extents: [],
          mappings: [],
        ),
        throwsFormatException,
      );
    },
  );
}
