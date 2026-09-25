import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/directory_idmap/directory_ldap_activation_panel.dart';
import 'package:truenas_api/truenas_api.dart';

DirectoryIdmapInventory inventory({
  bool enabled = false,
  bool protected = true,
}) => DirectoryIdmapInventory(
  endpoint: 'wss://nas.example.invalid/api/current',
  hostId: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  serviceType: 'LDAP',
  enabled: enabled,
  status: enabled ? 'HEALTHY' : 'DISABLED',
  builtin: null,
  primary: null,
  trusted: const [],
  ldap: DirectoryLdapOverview(
    serverUrls: [
      protected
          ? 'ldaps://ldap.example.invalid'
          : 'ldap://ldap.example.invalid',
    ],
    baseDn: 'dc=example,dc=invalid',
    schema: 'RFC2307',
    startTls: false,
    validateCertificates: protected,
    credentialType: 'LDAP_ANONYMOUS',
  ),
);

Future<void> showPanel(WidgetTester tester, DirectoryIdmapInventory data) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [DirectoryLdapActivationPanel(inventory: data)],
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('protected disabled LDAP exposes reviewed enable', (
    tester,
  ) async {
    await showPanel(tester, inventory());
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review LDAP enable'),
    );
    expect(button.onPressed, isNotNull);
    expect(find.text('Enable LDAP once'), findsNothing);
  });

  testWidgets('unencrypted disabled LDAP cannot be enabled', (tester) async {
    await showPanel(tester, inventory(protected: false));
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review LDAP enable'),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Enable is unavailable'), findsOneWidget);
  });

  testWidgets('healthy enabled LDAP exposes reviewed disable', (tester) async {
    await showPanel(tester, inventory(enabled: true));
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review LDAP disable'),
    );
    expect(button.onPressed, isNotNull);
    expect(find.text('Disable LDAP once'), findsNothing);
  });
}
