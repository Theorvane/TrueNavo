import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/directory_idmap/directory_ldap_editor.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  testWidgets('LDAP editor requires a changed encrypted proposal', (
    tester,
  ) async {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      serviceType: 'LDAP',
      enabled: false,
      status: 'DISABLED',
      builtin: null,
      primary: null,
      trusted: const [],
      ldap: DirectoryLdapOverview(
        serverUrls: ['ldaps://ldap.example.invalid'],
        baseDn: 'dc=example,dc=invalid',
        schema: 'RFC2307',
        startTls: false,
        validateCertificates: true,
        attributeMaps: DirectoryLdapAttributeMaps.parse(null),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [DirectoryLdapEditor(inventory: inventory)],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Change at least one LDAP setting.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review LDAP change'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byType(TextField).first,
      'ldap://ldap2.example.invalid',
    );
    await tester.pump();
    expect(
      find.text('Use LDAPS or StartTLS with certificate validation enabled.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byType(TextField).first,
      'ldaps://ldap2.example.invalid',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review LDAP change'),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.text('Submit once'), findsNothing);
    await tester.enterText(
      find.byType(TextField).first,
      'ldaps://ldap.example.invalid',
    );
    await tester.pump();
    final advanced = find.text('Advanced LDAP attribute mappings');
    await tester.ensureVisible(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    final passwd = find.text('passwd');
    await tester.ensureVisible(passwd);
    await tester.pumpAndSettle();
    await tester.tap(passwd);
    await tester.pumpAndSettle();
    final userName = find.byKey(const ValueKey('ldap-attr:passwd.user_name'));
    await tester.ensureVisible(userName);
    await tester.pumpAndSettle();
    await tester.enterText(userName, 'uid');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review LDAP change'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.enterText(userName, 'invalid name');
    await tester.pump();
    expect(
      find.text('Enter only supported LDAP attribute names.'),
      findsOneWidget,
    );
  });
}
