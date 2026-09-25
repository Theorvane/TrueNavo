import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_repository.dart';
import 'package:trueraid/features/management/management_controller.dart';
import 'package:trueraid/features/management/management_page.dart';
import 'package:trueraid/features/server_profiles/server_profile.dart';
import 'package:trueraid/features/server_profiles/server_profile_store.dart';
import 'package:trueraid/features/server_profiles/server_profiles_controller.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _server = 'wss://nas.example/api/current';
const _target = 'tank/Media';
const _delete = DeleteDatasetCommand(dataset: _target);

void main() {
  testWidgets(
    'destructive confirmation shows exact target and server and can cancel',
    (tester) async {
      bool? approved;
      await _pumpDialog(tester, _delete, onResult: (value) => approved = value);

      expect(find.text(_target), findsOneWidget);
      expect(find.text(_server), findsOneWidget);
      expect(find.text('Delete dataset?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      expect(_confirmButton(tester).onPressed, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(approved, isFalse);
      expect(find.byType(ManagementConfirmationDialog), findsNothing);
    },
  );

  testWidgets(
    'delete requires the full case-sensitive target without trimming',
    (tester) async {
      bool? approved;
      await _pumpDialog(tester, _delete, onResult: (value) => approved = value);
      final field = find.byKey(const Key('delete-confirm-target'));

      for (final invalid in [
        'Media',
        'tank/media',
        '$_target ',
        ' $_target',
        'tank',
        '',
      ]) {
        await tester.enterText(field, invalid);
        await tester.pump();
        expect(
          _confirmButton(tester).onPressed,
          isNull,
          reason: 'Rejected: "$invalid"',
        );
        expect(approved, isNull);
      }
      await tester.enterText(field, _target);
      await tester.pump();
      expect(_confirmButton(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('management-confirm')));
      await tester.pumpAndSettle();
      expect(approved, isTrue);
    },
  );

  testWidgets('missing live session exposes no write controls', (tester) async {
    final manager = _Manager();
    await _pumpPage(tester, manager, connected: false);

    expect(find.text('A live connection is required'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byKey(const Key('management-confirm')), findsNothing);
    expect(manager.commands, isEmpty);
  });

  testWidgets(
    'unverified version leaves monitoring explanation but no writes',
    (tester) async {
      final manager = _Manager(versionSupported: false);
      await _pumpPage(tester, manager);

      expect(
        find.text('Management is not verified for this version'),
        findsOneWidget,
      );
      expect(find.text('No changes have been made.'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(manager.commands, isEmpty);
    },
  );

  testWidgets(
    'unadvertised service capabilities disable every service action',
    (tester) async {
      final manager = _Manager(actions: const {});
      await _pumpPage(tester, manager);

      for (final action in ServiceControlAction.values) {
        final button = tester.widget<OutlinedButton>(
          find.byKey(ValueKey('service-ssh-${action.name}')),
        );
        expect(button.onPressed, isNull);
      }
      expect(
        find.text('Service control is not advertised by this server.'),
        findsOneWidget,
      );
      expect(manager.commands, isEmpty);
    },
  );

  testWidgets(
    'service action requires confirmation and cancellation sends nothing',
    (tester) async {
      final manager = _Manager();
      await _pumpPage(tester, manager);
      final stop = find.byKey(const ValueKey('service-ssh-stop'));
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();

      expect(find.text('Stop service?'), findsOneWidget);
      expect(
        find.textContaining('Active clients may lose access'),
        findsOneWidget,
      );
      expect(manager.commands, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(manager.commands, isEmpty);

      await tester.tap(stop);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('management-confirm')));
      await tester.pumpAndSettle();
      expect(manager.commands, hasLength(1));
      final command = manager.commands.single as ServiceControlCommand;
      expect(command.service, 'ssh');
      expect(command.action, ServiceControlAction.stop);
      expect(find.text('Change completed'), findsOneWidget);
    },
  );

  testWidgets(
    'pool root deletion stays disabled while child creation reviews full path',
    (tester) async {
      final manager = _Manager();
      await _pumpPage(tester, manager, storage: true);
      final rootDelete = tester.widget<TextButton>(
        find.byKey(const ValueKey('dataset-delete-tank')),
      );
      expect(rootDelete.onPressed, isNull);
      final create = find.byKey(const ValueKey('dataset-create-tank'));
      await tester.ensureVisible(create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('management-name'));
      await tester.enterText(field, '../escape');
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a name starting with a letter or number.'),
        findsOneWidget,
      );
      expect(manager.commands, isEmpty);

      await tester.enterText(field, 'projects');
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('tank/projects'), findsOneWidget);
      expect(find.text('Create dataset?'), findsOneWidget);
      expect(manager.commands, isEmpty);
      await tester.tap(find.byKey(const Key('management-confirm')));
      await tester.pumpAndSettle();
      expect(manager.commands, hasLength(1));
      final command = manager.commands.single as CreateDatasetCommand;
      expect(command.parent, 'tank');
      expect(command.name, 'projects');
    },
  );

  testWidgets('unknown completion retains the accepted job number on screen', (
    tester,
  ) async {
    final manager = _Manager(
      onExecute: (command) async => ManagementJobSubmitted(command, jobId: 42),
      onPoll: (job) async =>
          ManagementOutcomeUnknown(job.command, jobId: job.jobId),
    );
    await _pumpPage(tester, manager);
    final restart = find.byKey(const ValueKey('service-ssh-restart'));
    await tester.ensureVisible(restart);
    await tester.tap(restart);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('management-confirm')));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ManagementPage)),
    );
    final state = container.read(managementControllerProvider);
    expect(state.phase, ManagementPhase.unknown);
    expect((state.result as ManagementOutcomeUnknown).jobId, 42);
    expect(find.text('Result needs verification'), findsOneWidget);
    final jobLabel = find.text('Job #42');
    expect(jobLabel, findsOneWidget);
    await tester.ensureVisible(jobLabel);
    expect(jobLabel.hitTestable(), findsOneWidget);
    expect(manager.commands, hasLength(1));
    expect(manager.polledJobs, hasLength(1));
  });

  testWidgets('unverified display-only identities cannot be used as targets', (
    tester,
  ) async {
    final manager = _Manager();
    await _pumpPage(tester, manager, verifiedIdentity: false);

    expect(
      find.text('Exact service identity could not be verified.'),
      findsOneWidget,
    );
    for (final action in ServiceControlAction.values) {
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(ValueKey('service-ssh-${action.name}')),
            )
            .onPressed,
        isNull,
      );
    }
    expect(manager.commands, isEmpty);
  });

  for (final width in [320.0, 1440.0]) {
    for (final dark in [false, true]) {
      for (final storage in [false, true]) {
        testWidgets(
          '${storage ? 'storage' : 'services'} at ${width.toInt()}px 2x ${dark ? 'dark' : 'light'} has no overflow',
          (tester) async {
            await _pumpPage(
              tester,
              _Manager(),
              storage: storage,
              size: Size(width, 1100),
              textScale: 2,
              dark: dark,
            );
            await tester.drag(
              find.byType(ListView).first,
              const Offset(0, -750),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
      testWidgets(
        'confirmation at ${width.toInt()}px 2x ${dark ? 'dark' : 'light'} has no overflow',
        (tester) async {
          await _pumpDialog(
            tester,
            _delete,
            size: Size(width, 1100),
            textScale: 2,
            dark: dark,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

FilledButton _confirmButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('management-confirm')));

Future<void> _pumpDialog(
  WidgetTester tester,
  ManagementCommand command, {
  ValueChanged<bool?>? onResult,
  Size size = const Size(800, 1100),
  double textScale = 1,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app(
      size: size,
      textScale: textScale,
      dark: dark,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showDialog<bool>(
                context: context,
                builder: (_) => ManagementConfirmationDialog(
                  command: command,
                  serverLabel: _server,
                ),
              );
              onResult?.call(result);
            },
            child: const Text('Open confirmation'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open confirmation'));
  await tester.pumpAndSettle();
}

Future<void> _pumpPage(
  WidgetTester tester,
  _Manager manager, {
  bool connected = true,
  bool storage = false,
  bool verifiedIdentity = true,
  Size size = const Size(800, 1100),
  double textScale = 1,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final session = AuthenticatedSession(
    profileId: 'nas',
    repository: manager,
    availableMethodNames: const {'service.control', 'core.get_jobs'},
    version: manager.versionSupported ? '25.10.1' : '99.0',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardActiveSessionProvider.overrideWithValue(
          connected ? session : null,
        ),
        managementPollDelayProvider.overrideWithValue(() async {}),
        initialServerProfileSnapshotProvider.overrideWithValue(
          ServerProfileSnapshot(
            profiles: const [
              ServerProfile(
                id: 'nas',
                displayName: 'Production NAS',
                originalHostInput: 'nas.example',
                normalizedEndpoint: _server,
                lastKnownVersion: '25.10.1',
              ),
            ],
            selectedProfileId: 'nas',
          ),
        ),
        dashboardLoadProvider('workloads').overrideWith(
          (ref) async => DashboardData(
            DashboardWorkloads(
              services: [
                DashboardService(
                  name: 'ssh',
                  status: 'RUNNING',
                  statusKind: DashboardStatus.success,
                  managementId: verifiedIdentity ? 'ssh' : null,
                ),
              ],
              servicesAvailable: true,
            ),
          ),
        ),
        dashboardLoadProvider('storage').overrideWith(
          (ref) async => const DashboardData(
            DashboardStorage(
              pools: [],
              datasets: [
                DashboardDataset(
                  name: 'tank',
                  poolName: 'tank',
                  managementId: 'tank',
                ),
                DashboardDataset(
                  name: _target,
                  poolName: 'tank',
                  managementId: _target,
                ),
              ],
              poolsAvailable: true,
              datasetsAvailable: true,
            ),
          ),
        ),
      ],
      child: _app(
        size: size,
        textScale: textScale,
        dark: dark,
        home: ManagementPage(initialStorage: storage),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _app({
  required Size size,
  required double textScale,
  required bool dark,
  required Widget home,
}) => MaterialApp(
  theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(size: size, textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: home,
);

class _Manager implements SessionRepository, AuthenticatedSessionManagement {
  _Manager({
    this.versionSupported = true,
    this.actions,
    this.onExecute,
    this.onPoll,
  });
  final bool versionSupported;
  final Set<ManagementAction>? actions;
  final Future<ManagementResult> Function(ManagementCommand)? onExecute;
  final Future<ManagementResult> Function(ManagementJobSubmitted)? onPoll;
  final commands = <ManagementCommand>[];
  final polledJobs = <ManagementJobSubmitted>[];
  @override
  ManagementCapabilities get managementCapabilities => ManagementCapabilities(
    connected: true,
    versionSupported: versionSupported,
    availableActions: actions ?? ManagementAction.values.toSet(),
  );
  @override
  Future<ManagementResult> execute(ManagementCommand command) async {
    commands.add(command);
    return onExecute == null
        ? ManagementCompleted(command)
        : await onExecute!(command);
  }

  @override
  Future<ManagementResult> pollJob(ManagementJobSubmitted job) async {
    polledJobs.add(job);
    return onPoll == null
        ? ManagementCompleted(job.command)
        : await onPoll!(job);
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('Tests never open a network connection.');
}
