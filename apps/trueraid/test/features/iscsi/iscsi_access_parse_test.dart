import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';

void main() {
  test(
    'null initiator means any initiator without retaining CHAP reference',
    () {
      final overview = IscsiOverview.parse(
        portals: [
          {
            'id': 1,
            'listen': [
              {'ip': '::', 'port': 3260},
            ],
          },
        ],
        initiators: [],
        targets: [
          {
            'id': 2,
            'name': 'target',
            'groups': [
              {
                'portal': 1,
                'initiator': null,
                'authmethod': 'CHAP_MUTUAL',
                'auth': 42,
              },
            ],
          },
        ],
        extents: [],
        mappings: [],
      );
      final group = overview.targets.single.groups.single;
      expect(group.initiatorId, isNull);
      expect(group.authMethod, 'Mutual CHAP');
      expect(group.toString(), isNot(contains('42')));
    },
  );

  test('nested truncated access lists fail closed', () {
    expect(
      () => IscsiOverview.parse(
        portals: [
          {
            'id': 1,
            'listen': ['[additional items omitted]'],
          },
        ],
        initiators: [],
        targets: [],
        extents: [],
        mappings: [],
      ),
      throwsFormatException,
    );
    expect(
      () => IscsiOverview.parse(
        portals: [],
        initiators: [],
        targets: [
          {
            'id': 2,
            'name': 'target',
            'groups': ['[additional items omitted]'],
          },
        ],
        extents: [],
        mappings: [],
      ),
      throwsFormatException,
    );
  });
}
