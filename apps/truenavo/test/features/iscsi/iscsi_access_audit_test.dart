import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/iscsi/iscsi_access_audit.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  testWidgets('counts associations and flags missing or unused references', (
    tester,
  ) async {
    final overview = IscsiOverview.parse(
      portals: [
        {'id': 1, 'listen': []},
        {'id': 2, 'listen': []},
      ],
      initiators: [
        {'id': 3, 'initiators': <String>[]},
        {'id': 4, 'initiators': <String>[]},
      ],
      targets: [
        {
          'id': 5,
          'name': 'target',
          'groups': [
            {'portal': 1, 'initiator': 3, 'authmethod': 'CHAP'},
            {'portal': 99, 'initiator': 88, 'authmethod': 'NONE'},
            {'portal': 1, 'initiator': null, 'authmethod': 'FUTURE'},
          ],
        },
      ],
      extents: [],
      mappings: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueNavoTheme.dark(),
        home: Scaffold(body: IscsiAccessAudit(overview: overview)),
      ),
    );
    expect(find.text('CHAP · 1 of 3'), findsOneWidget);
    expect(find.text('No CHAP · 1 of 3'), findsOneWidget);
    expect(find.text('Authentication unknown · 1 of 3'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('iscsi-access-chap')),
          )
          .value,
      1 / 3,
    );
    expect(
      find.textContaining('1 portal, 1 initiator group. Reload'),
      findsOneWidget,
    );
    expect(
      find.textContaining('1 portal, 1 initiator group. This'),
      findsOneWidget,
    );
    expect(find.textContaining('current sessions'), findsOneWidget);
  });

  testWidgets('empty associations have no fabricated percentages', (
    tester,
  ) async {
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [],
      extents: [],
      mappings: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueNavoTheme.dark(),
        home: Scaffold(body: IscsiAccessAudit(overview: overview)),
      ),
    );
    expect(
      find.text('No target access associations configured.'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
