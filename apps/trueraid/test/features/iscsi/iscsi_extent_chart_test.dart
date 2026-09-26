import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/iscsi/iscsi_extent_chart.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  testWidgets('shows bounded configuration proportions including unknowns', (
    tester,
  ) async {
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [],
      mappings: [],
      extents: [
        {'id': 1, 'name': 'disk', 'type': 'DISK', 'enabled': true},
        {'id': 2, 'name': 'file', 'type': 'FILE', 'enabled': false},
        {'id': 3, 'name': 'unknown', 'type': 'OTHER'},
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueRAIDTheme.dark(),
        home: Scaffold(body: IscsiExtentChart(overview: overview)),
      ),
    );
    expect(find.textContaining('Not capacity, I/O'), findsOneWidget);
    for (final key in [
      'type-disk',
      'type-file',
      'type-unknown-type',
      'state-enabled',
      'state-disabled',
      'state-status-unknown',
    ]) {
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(Key('iscsi-extent-$key')),
            )
            .value,
        closeTo(1 / 3, 0.00001),
      );
    }
  });

  testWidgets('empty inventory has no fabricated ratio', (tester) async {
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [],
      mappings: [],
      extents: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueRAIDTheme.dark(),
        home: Scaffold(body: IscsiExtentChart(overview: overview)),
      ),
    );
    expect(find.text('No extents configured.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
