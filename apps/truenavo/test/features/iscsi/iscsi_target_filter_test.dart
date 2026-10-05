import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo/features/iscsi/iscsi_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  testWidgets('filters target cards by name, ID and mapped extent', (
    tester,
  ) async {
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: [
        {'id': 10, 'name': 'Alpha'},
        {'id': 20, 'name': 'Beta'},
      ],
      extents: [
        {'id': 30, 'name': 'Archive'},
      ],
      mappings: [
        {'id': 40, 'target': 20, 'extent': 30, 'lunid': 0},
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          iscsiOverviewProvider.overrideWith((ref) async => overview),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const IscsiPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final filter = find.byKey(const Key('iscsi-target-filter'));
    await tester.scrollUntilVisible(
      filter,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('iscsi-target-10')), findsOneWidget);
    expect(find.byKey(const Key('iscsi-target-20')), findsOneWidget);

    await tester.enterText(filter, 'beta');
    await tester.pump();
    expect(find.byKey(const Key('iscsi-target-10')), findsNothing);
    expect(find.byKey(const Key('iscsi-target-20')), findsOneWidget);
    expect(
      find.text(
        'Showing 1 of 2 targets. Local filter only; charts and other inventory remain unfiltered.',
      ),
      findsOneWidget,
    );

    await tester.enterText(filter, '10');
    await tester.pump();
    expect(find.byKey(const Key('iscsi-target-10')), findsOneWidget);
    expect(find.byKey(const Key('iscsi-target-20')), findsNothing);

    await tester.enterText(filter, 'archive');
    await tester.pump();
    expect(find.byKey(const Key('iscsi-target-10')), findsNothing);
    expect(find.byKey(const Key('iscsi-target-20')), findsOneWidget);

    await tester.enterText(filter, 'absent');
    await tester.pump();
    expect(find.text('No targets match this local filter.'), findsOneWidget);
    expect(find.byKey(const Key('iscsi-target-10')), findsNothing);
    expect(find.byKey(const Key('iscsi-target-20')), findsNothing);
  });
}
