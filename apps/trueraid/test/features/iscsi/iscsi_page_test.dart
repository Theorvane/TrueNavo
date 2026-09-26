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
    expect(find.text('Portal listener address choices'), findsOneWidget);
    expect(find.text('Pool free-space alert threshold'), findsOneWidget);
    expect(find.text('Portal description'), findsOneWidget);
    expect(find.text('Initiator group description'), findsOneWidget);
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
}
