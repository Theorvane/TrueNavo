import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/iscsi/iscsi_mapping_chart.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  testWidgets('bars use all configured mappings as denominator', (
    tester,
  ) async {
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [
        {'id': 1, 'name': 'first'},
        {'id': 2, 'name': 'second'},
      ],
      extents: [],
      mappings: [
        {'id': 1, 'target': 1, 'extent': 10, 'lunid': 0},
        {'id': 2, 'target': 1, 'extent': 11, 'lunid': 1},
        {'id': 3, 'target': 2, 'extent': 12, 'lunid': 0},
        {'id': 4, 'target': 999, 'extent': 13, 'lunid': 0},
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueRAIDTheme.dark(),
        home: Scaffold(body: IscsiMappingChart(overview: overview)),
      ),
    );
    expect(find.text('first · 2 of 4'), findsOneWidget);
    expect(find.text('second · 1 of 4'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('iscsi-target-mappings-1')),
          )
          .value,
      0.5,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('iscsi-target-mappings-2')),
          )
          .value,
      0.25,
    );
    expect(
      find.text('1 mapping references targets missing from this read.'),
      findsOneWidget,
    );
  });

  testWidgets('zero mappings is an explicit empty state', (tester) async {
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [],
      extents: [],
      mappings: [],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueRAIDTheme.dark(),
        home: Scaffold(body: IscsiMappingChart(overview: overview)),
      ),
    );
    expect(find.text('No LUN mappings configured.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
