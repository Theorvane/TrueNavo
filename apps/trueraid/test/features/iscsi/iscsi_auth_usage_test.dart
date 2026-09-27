import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/iscsi/iscsi_auth_usage.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test(
    'counts target and discovery use without treating orphan as safe to delete',
    () {
      final inventory = IscsiAuthInventory([
        const IscsiAuthReference(
          id: 3,
          tag: 9,
          user: 'client',
          peerUser: '',
          discoveryAuth: 'NONE',
        ),
        const IscsiAuthReference(
          id: 4,
          tag: 10,
          user: 'discovery',
          peerUser: '',
          discoveryAuth: 'CHAP',
        ),
        const IscsiAuthReference(
          id: 5,
          tag: 11,
          user: 'unreferenced',
          peerUser: '',
          discoveryAuth: 'NONE',
        ),
      ], DateTime.utc(2026));
      final overview = IscsiOverview.parse(
        portals: [],
        initiators: [],
        extents: [],
        mappings: [],
        targets: [
          {
            'id': 7,
            'name': 'one',
            'groups': [
              {'portal': 2, 'authmethod': 'CHAP', 'auth': 3},
              {'portal': 2, 'authmethod': 'CHAP', 'auth': 99},
              {'portal': 2, 'authmethod': 'CHAP', 'auth': null},
              {'portal': 2, 'authmethod': 'NONE', 'auth': 3},
            ],
          },
          {
            'id': 8,
            'name': 'two',
            'groups': [
              {'portal': 2, 'authmethod': 'CHAP_MUTUAL', 'auth': 3},
            ],
          },
        ],
      );
      final usage = IscsiAuthUsage.from(inventory, overview);
      expect(usage.total, 3);
      expect(usage.used, 2);
      expect(usage.unreferenced, 1);
      expect(usage.targetUses[3], 2);
      expect(usage.targetUses[4], isNull);
      expect(usage.missingIds, {99});
      expect(usage.chapWithoutId, 1);
      expect(usage.noChapWithId, 1);
    },
  );
}
