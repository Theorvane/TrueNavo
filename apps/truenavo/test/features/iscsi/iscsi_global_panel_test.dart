import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/iscsi/iscsi_global.dart';
import 'package:truenavo/features/iscsi/iscsi_global_panel.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  testWidgets('shows saved settings distinctly from reported service state', (
    tester,
  ) async {
    final summary = IscsiGlobalSummary(
      observedAt: DateTime.utc(2026),
      config: IscsiGlobalConfig.parse({
        'basename': 'iqn.example',
        'isns_servers': <String>[],
        'listen_port': 3260,
        'pool_avail_threshold': 25,
        'alua': false,
        'iser': true,
        'private_token': 'hidden',
      }),
      service: const IscsiServiceStatus(enabledOnBoot: true, state: 'STOPPED'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [iscsiGlobalProvider.overrideWith((ref) async => summary)],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(body: IscsiGlobalPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Target base name: iqn.example'), findsOneWidget);
    expect(find.text('Pool free-space threshold: 25%'), findsOneWidget);
    expect(find.text('Service: STOPPED'), findsOneWidget);
    expect(find.text('Start on boot: Enabled'), findsOneWidget);
    expect(find.textContaining('hidden'), findsNothing);
  });

  testWidgets('unknown runtime state remains unknown', (tester) async {
    final summary = IscsiGlobalSummary(
      observedAt: DateTime.utc(2026),
      config: IscsiGlobalConfig.parse({
        'basename': 'iqn.example',
        'isns_servers': <String>[],
        'alua': false,
        'iser': false,
      }),
      service: null,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [iscsiGlobalProvider.overrideWith((ref) async => summary)],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(body: IscsiGlobalPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Service: Status unavailable'), findsOneWidget);
    expect(find.text('Start on boot: Unknown'), findsOneWidget);
    expect(find.text('Listen port: Not reported'), findsOneWidget);
  });
}
