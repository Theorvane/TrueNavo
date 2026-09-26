import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid/features/iscsi/iscsi_page.dart';

void main() {
  testWidgets('shows target LUN and extent state without private fields', (
    tester,
  ) async {
    final overview = IscsiOverview.parse(
      portals: [
        {
          'id': 4,
          'listen': [
            {'ip': '2001:db8::1', 'port': 3260},
          ],
        },
      ],
      initiators: [
        {
          'id': 5,
          'initiators': ['iqn.example:client'],
        },
      ],
      targets: [
        {
          'id': 1,
          'name': 'target-one',
          'mode': 'ISCSI',
          'groups': [
            {'portal': 4, 'initiator': 5, 'authmethod': 'CHAP', 'auth': 99},
          ],
        },
      ],
      extents: [
        {
          'id': 2,
          'name': 'extent-two',
          'type': 'DISK',
          'enabled': true,
          'serial': 'hidden-serial',
          'path': '/mnt/private',
        },
      ],
      mappings: [
        {'id': 3, 'target': 1, 'extent': 2, 'lunid': 0},
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          iscsiOverviewProvider.overrideWith((ref) async => overview),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const IscsiPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('target-one'), findsOneWidget);
    expect(find.text('Configured access associations'), findsOneWidget);
    expect(find.text('Extent configuration distribution'), findsOneWidget);
    expect(find.text('Portal listener address choices'), findsOneWidget);
    expect(find.text('Pool free-space alert threshold'), findsOneWidget);
    expect(find.text('Portal description'), findsOneWidget);
    expect(find.text('Initiator group description'), findsOneWidget);
    expect(find.text('Extent description'), findsOneWidget);
    expect(find.text('Check new target name'), findsOneWidget);
    expect(find.text('Create an unbound iSCSI target'), findsOneWidget);
    expect(find.text('LUN 0 → extent-two'), findsOneWidget);
    expect(
      find.textContaining('extent-two · Disk · Enabled · Mapped'),
      findsOneWidget,
    );
    expect(find.textContaining('[2001:db8::1]:3260'), findsWidgets);
    expect(find.textContaining('iqn.example:client'), findsWidgets);
    expect(find.textContaining('CHAP'), findsWidgets);
    expect(find.textContaining('auth: 99'), findsNothing);
    expect(find.textContaining('hidden-serial'), findsNothing);
    expect(find.textContaining('/mnt/private'), findsNothing);
    final ratio = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('iscsi-mapped-ratio')),
    );
    expect(ratio.value, 1);
  });

  testWidgets(
    'extent filter finds names, IDs and mapped target names locally',
    (tester) async {
      var overview = IscsiOverview.parse(
        portals: [],
        initiators: [],
        targets: [
          {'id': 4, 'name': 'archive-target'},
        ],
        extents: [
          {'id': 2, 'name': 'cold-disk', 'type': 'DISK'},
          {'id': 3, 'name': 'hot-file', 'type': 'FILE'},
        ],
        mappings: [
          {'id': 7, 'target': 4, 'extent': 2, 'lunid': 0},
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            iscsiOverviewProvider.overrideWith((ref) async => overview),
          ],
          child: MaterialApp(
            theme: TrueRAIDTheme.dark(),
            home: const IscsiPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final filter = find.byKey(const Key('iscsi-extent-filter'));
      await tester.ensureVisible(filter);
      await tester.enterText(filter, 'archive-target');
      await tester.pumpAndSettle();
      expect(find.textContaining('cold-disk · Disk'), findsOneWidget);
      expect(find.textContaining('hot-file · File'), findsNothing);
      expect(
        find.text(
          'Showing 1 of 2 extents. Local filter only; charts and summary remain unfiltered.',
        ),
        findsOneWidget,
      );

      await tester.enterText(filter, '3');
      await tester.pumpAndSettle();
      expect(find.textContaining('hot-file · File'), findsOneWidget);
      expect(find.textContaining('cold-disk · Disk'), findsNothing);

      await tester.enterText(filter, 'missing');
      await tester.pumpAndSettle();
      expect(find.text('No extents match this local filter.'), findsOneWidget);
      expect(find.text('Extent configuration distribution'), findsOneWidget);

      overview = IscsiOverview.parse(
        portals: [],
        initiators: [],
        targets: [],
        extents: [
          {'id': 9, 'name': 'new-extent', 'type': 'DISK'},
        ],
        mappings: [],
      );
      ProviderScope.containerOf(tester.element(find.byType(IscsiPage)))
          .invalidate(iscsiOverviewProvider);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Showing 1 of 1 extents. Local filter only; charts and summary remain unfiltered.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: filter, matching: find.byType(EditableText)),
            )
            .controller
            .text,
        isEmpty,
      );
    },
  );
}
