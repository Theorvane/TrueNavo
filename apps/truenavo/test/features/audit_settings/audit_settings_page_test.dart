import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/audit_settings/audit_settings_page.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const _endpoint = 'wss://nas.example/api/current';
const _host =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

final class _FakeAudit
    implements SessionRepository, AuthenticatedAuditSettingsSession {
  @override
  AuditSettingsCapabilities get auditSettingsCapabilities =>
      const AuditSettingsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canUpdate: true,
      );

  @override
  Future<AuditSettingsInventory> loadAuditSettings() async =>
      AuditSettingsInventory(
        readiness: AlertSettingsInventory(
          endpoint: _endpoint,
          hostId: _host,
          bootId: 'boot',
          currentVersion: '25.10.1',
          state: 'READY',
          fullAdmin: true,
          failoverLicensed: false,
          conflictingJob: false,
          bootPool: 'boot-pool',
          bootHealthy: true,
          environments: const [
            BootEnvironmentSnapshot(
              id: '25.10.1',
              dataset: 'boot-pool/ROOT/25.10.1',
              created: '2026-09-15',
              usedBytes: 1,
              active: true,
              activated: true,
              keep: true,
              canActivate: true,
            ),
          ],
          services: const [],
        ),
        settings: const AuditSettingsSnapshot(
          id: 1,
          retentionDays: 30,
          reservationGiB: 0,
          quotaGiB: 20,
          warningPercent: 75,
          criticalPercent: 90,
          remoteLoggingEnabled: false,
          usedBytes: 1024,
          usedByDatasetBytes: 1024,
          usedBySnapshotsBytes: 0,
          availableBytes: 2048,
        ),
      );

  @override
  Future<AuditSettingsReview> reviewAuditSettings(
    AuditSettingsRequest request,
  ) => throw UnimplementedError();

  @override
  Future<AuditSettingsResult> executeAuditSettings(
    AuditSettingsReview review,
    String confirmation, {
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

void main() {
  testWidgets('disconnected audit settings never offer an update', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(null)],
        child: const MaterialApp(home: AuditSettingsPage()),
      ),
    );
    expect(find.text('Audit storage & retention'), findsOneWidget);
    expect(find.textContaining('unavailable'), findsOneWidget);
    expect(find.text('Change retention'), findsNothing);
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Load / refresh configuration'),
    );
    expect(button.onPressed, isNull);
  });
  testWidgets("storage policy editor shows bounded native fields", (
    tester,
  ) async {
    final api = _FakeAudit();
    final session = AuthenticatedSession(
      profileId: "p",
      repository: api,
      availableMethodNames: const {},
      version: "25.10.1",
      endpoint: _endpoint,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [dashboardActiveSessionProvider.overrideWithValue(session)],
        child: const MaterialApp(home: AuditSettingsPage()),
      ),
    );
    await tester.tap(find.text("Load / refresh configuration"));
    await tester.pumpAndSettle();
    expect(find.text("Retention: 30 / 30 days"), findsOneWidget);
    await tester.ensureVisible(find.text("Change storage policy"));
    await tester.tap(find.text("Change storage policy"));
    await tester.pumpAndSettle();
    expect(find.text("Review audit storage"), findsOneWidget);
    expect(find.text("Reservation GiB"), findsOneWidget);
    expect(find.text("Quota GiB (0 disables)"), findsOneWidget);
    expect(find.text("Warning percent"), findsOneWidget);
    expect(find.text("Critical percent"), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, "Review"))
          .onPressed,
      isNull,
    );
  });
}
