import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/audit_export/audit_export_page.dart';
import 'package:trueraid/features/configuration_backup/configuration_backup_file.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _endpoint = 'wss://nas.example/api/current';

final class _FakeApi
    implements SessionRepository, AuthenticatedAuditExportSession {
  @override
  AuditExportCapabilities get auditExportCapabilities =>
      const AuditExportCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        transferSupported: true,
      );

  @override
  Future<AuditExportReview> reviewAuditExport(AuditExportRequest request) =>
      throw UnimplementedError();

  @override
  Future<AuditExportResult> executeAuditExport(
    AuditExportReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) => throw UnimplementedError();

  @override
  Future<AuditExportResult> pollAuditExport(
    AuditExportOperation operation, {
    required bool Function() isCurrent,
  }) => throw UnimplementedError();

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

final class _Saver implements ConfigurationBackupFileSaver {
  @override
  bool get supported => true;
  @override
  void cancel() {}
  @override
  Future<ConfigurationBackupSaveOutcome> save({
    required Uint8List bytes,
    required String filename,
    required bool Function() isCurrent,
  }) => throw UnimplementedError();
}

void main() {
  testWidgets('disconnected export offers no report action', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: MaterialApp(
          theme: TrueRAIDTheme.light(),
          home: const AuditExportPage(),
        ),
      ),
    );
    expect(find.text('Export a bounded audit report'), findsOneWidget);
    expect(find.text('Audit export unavailable'), findsOneWidget);
    expect(find.byKey(const Key('audit-export-review')), findsNothing);
  });

  testWidgets('connected export shows bounded filters and three disclosures', (
    tester,
  ) async {
    final api = _FakeApi();
    final session = AuthenticatedSession(
      profileId: 'p',
      repository: api,
      availableMethodNames: const {},
      version: '25.10.1',
      endpoint: _endpoint,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWithValue(session),
          configurationBackupFileSaverProvider.overrideWithValue(_Saver()),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.light(),
          home: const AuditExportPage(),
        ),
      ),
    );
    expect(find.byKey(const Key('audit-export-service')), findsOneWidget);
    expect(find.byKey(const Key('audit-export-format')), findsOneWidget);
    expect(find.byKey(const Key('audit-export-interval')), findsOneWidget);
    expect(find.byKey(const Key('audit-export-result')), findsOneWidget);
    expect(find.byKey(const Key('audit-export-username')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Required disclosures'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('audit-export-sensitive')), findsOneWidget);
    expect(find.byKey(const Key('audit-export-artifact')), findsOneWidget);
    expect(find.byKey(const Key('audit-export-limit')), findsOneWidget);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review export'),
    );
    expect(review.onPressed, isNull);
  });
}
