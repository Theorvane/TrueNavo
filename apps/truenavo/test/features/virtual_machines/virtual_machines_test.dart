import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/dev/virtual_machines_preview.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/virtual_machines/virtual_machines_controller.dart';
import 'package:truenavo/features/virtual_machines/virtual_machines_page.dart';
import 'package:truenavo/features/virtual_machines/vm_state_chart.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _handle = VmOperationHandle(id: 88, targetName: 'guest');
final _review = VmReview(
  title: 'Delete virtual machine',
  targetName: 'guest',
  identity: '11111111-1111-4111-8111-111111111111',
  changes: const ['Remove VM definition'],
  warnings: const ['Backing zvols and files are retained.'],
);

void main() {
  testWidgets(
    'state donut exposes disjoint returned-inventory counts and semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: VmStateChart(
              states: [
                'RUNNING',
                'STOPPED',
                'SUSPENDED',
                'SUSPENDED',
                'ERROR',
                'STARTING',
              ],
            ),
          ),
        ),
      );
      expect(find.text('Running · 1'), findsOneWidget);
      expect(find.text('Stopped · 1'), findsOneWidget);
      expect(find.text('Suspended · 2'), findsOneWidget);
      expect(find.text('Other states · 2'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'VM inventory state counts. 6 total; 1 running, 1 stopped, 2 suspended, 2 other states.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Returned VM inventory, not runtime utilization or uptime.'),
        findsOneWidget,
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'empty state donut has an explicit no-inventory message and no percentages',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(body: VmStateChart(states: [])),
        ),
      );
      expect(
        find.text('No virtual machines in this inventory.'),
        findsOneWidget,
      );
      expect(find.text('Running · 0'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'VM inventory state counts. No virtual machines in the returned inventory.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('%'), findsNothing);
      semantics.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('VM badges expose state names without relying on color', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueNavoTheme.dark(),
        home: const Scaffold(
          body: Column(
            children: [
              VmStateBadge(state: 'RUNNING'),
              VmStateBadge(state: 'STOPPED'),
              VmStateBadge(state: 'SUSPENDED'),
              VmStateBadge(state: 'ERROR'),
            ],
          ),
        ),
      ),
    );
    for (final state in ['Running', 'Stopped', 'Suspended', 'Error']) {
      expect(find.bySemanticsLabel('VM state: $state'), findsOneWidget);
      expect(find.text(state), findsOneWidget);
    }
    final success = tester.widget<Text>(find.text('Running')).style!.color;
    final stopped = tester.widget<Text>(find.text('Stopped')).style!.color;
    expect(success, isNot(stopped));
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });
  test(
    'preview inventory and reviews never admit execution or polling',
    () async {
      final api = _Preview();
      final inventory = await api.loadVirtualMachines();
      expect(inventory.machines.length, 2);
      expect((await api.loadVmChoices()).disks, isNotEmpty);
      final lifecycle = await api.reviewVmAction(
        inventory.machines.first,
        VmAction.stop,
      );
      final create = await api.reviewVmCreate(
        const VmConfiguration(name: 'preview_guest', memoryMiB: 2048),
      );
      for (final review in [lifecycle, create]) {
        expect(
          (await api.executeVmReview(
            review,
            confirmation: review.targetName,
          )).outcome,
          VmOperationOutcome.rejected,
        );
      }
      expect(
        (await api.pollVmOperation(_handle)).outcome,
        VmOperationOutcome.rejected,
      );
    },
  );
  test(
    'controller excludes duplicate writes and holds the shared lock',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      final pending = Completer<VmOperationResult>();
      h.api.onWrite = () => pending.future;
      final first = h.execute();
      await h.execute();
      expect(h.api.writes, 1);
      expect(h.lock.acquire(), isNull);
      pending.complete(
        const VmOperationResult(outcome: VmOperationOutcome.verified),
      );
      await first;
      expect(h.state.locked, false);
      expect(h.lock.acquire(), isNotNull);
    },
  );
  test('a different workflow lock prevents VM dispatch', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    final owner = h.lock.acquire()!;
    await h.execute();
    expect(h.api.writes, 0);
    expect(h.state.result!.outcome, VmOperationOutcome.rejected);
    h.lock.release(owner);
  });
  test('unknown outcome retains lock and never repeats mutation', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.api.onWrite = () async => throw StateError('private-token');
    await h.execute();
    await h.execute();
    await h.controller.checkProgress();
    expect(h.api.writes, 1);
    expect(h.api.polls, 0);
    expect(h.state.unknown, true);
    expect(h.lock.acquire(), isNull);
    expect(h.state.result!.userMessage, isNot(contains('private-token')));
  });
  test(
    'late completion stays unknown with original-server provenance',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      final pending = Completer<VmOperationResult>();
      h.api.onWrite = () => pending.future;
      final first = h.execute();
      h.active = null;
      h.container.invalidate(dashboardActiveSessionProvider);
      h.container.read(dashboardActiveSessionProvider);
      pending.complete(
        const VmOperationResult(outcome: VmOperationOutcome.verified),
      );
      await first;
      expect(h.state.unknown, true);
      expect(h.state.target, 'guest');
      expect(h.state.server, h.session.endpoint);
      expect(h.state.identity, _review.identity);
      expect(h.state.connectionCurrent, false);
      expect(h.api.writes, 1);
    },
  );
  test(
    'late job receipt is retained only as original unresolved provenance',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      final pending = Completer<VmOperationResult>();
      h.api.onWrite = () => pending.future;
      final first = h.execute();
      h.active = null;
      h.container.invalidate(dashboardActiveSessionProvider);
      h.container.read(dashboardActiveSessionProvider);
      pending.complete(
        const VmOperationResult(
          outcome: VmOperationOutcome.submitted,
          operation: _handle,
        ),
      );
      await first;
      await h.controller.checkProgress();
      expect(h.state.unknown, true);
      expect(h.state.result!.operation, same(_handle));
      expect(h.state.server, h.session.endpoint);
      expect(h.api.polls, 0);
    },
  );
  testWidgets(
    'pending operation identifies original server and job after disconnect',
    (tester) async {
      final h = await _pump(tester);
      h.api.onWrite = () async => const VmOperationResult(
        outcome: VmOperationOutcome.submitted,
        operation: _handle,
      );
      await h.execute();
      h.active = null;
      h.container.invalidate(dashboardActiveSessionProvider);
      await tester.pumpAndSettle();
      expect(find.text('Original-server VM operation'), findsOneWidget);
      expect(
        find.text('Original server: wss://fixture.example/api/current'),
        findsOneWidget,
      );
      expect(find.text('Reviewed VM: guest'), findsOneWidget);
      expect(find.text('Original job ID: 88'), findsOneWidget);
      expect(find.text('Check progress'), findsNothing);
      expect(h.api.polls, 0);
    },
  );
  test(
    'owned pending job can be polled without repeating the mutation',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      h.api.onWrite = () async => const VmOperationResult(
        outcome: VmOperationOutcome.submitted,
        operation: _handle,
      );
      await h.execute();
      expect(h.lock.acquire(), isNull);
      await h.controller.checkProgress();
      expect(h.api.polls, 1);
      expect(h.api.writes, 1);
      expect(h.state.result!.outcome, VmOperationOutcome.verified);
      expect(h.lock.acquire(), isNotNull);
    },
  );
  testWidgets('native inventory renders without writes or overflow', (
    tester,
  ) async {
    final h = await _pump(tester);
    expect(find.text('Create virtual machine'), findsOneWidget);
    await _reveal(tester, find.text('guest'));
    expect(find.text('guest'), findsOneWidget);
    expect(find.textContaining('2048 MiB'), findsOneWidget);
    expect(h.api.writes, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'filtering rows does not rewrite returned inventory state counts',
    (tester) async {
      final h = await _pump(tester);
      expect(find.text('Stopped · 1'), findsOneWidget);
      final filter = find.byType(TextField).first;
      await _reveal(tester, filter);
      await tester.enterText(filter, 'no-match');
      await tester.pumpAndSettle();
      expect(find.text('No virtual machines match this view.'), findsOneWidget);
      expect(find.text('Stopped · 1'), findsOneWidget);
      expect(h.api.writes, 0);
    },
  );
  testWidgets('VM settings fields retain 14px control spacing', (tester) async {
    final h = await _pump(tester);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Create virtual machine'),
    );
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );
    final first = tester.getRect(fields.at(0));
    final second = tester.getRect(fields.at(1));
    expect(second.top - first.bottom, closeTo(14, 0.1));
    expect(h.api.writes, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('VM device selectors retain 14px control spacing', (
    tester,
  ) async {
    final h = await _pump(tester);
    final add = find.widgetWithText(OutlinedButton, 'Add device');
    await _reveal(tester, add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    final type = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(DropdownButtonFormField<String>),
        )
        .first;
    final choice = find.byType(DropdownButtonFormField<VmDeviceOption>);
    expect(
      tester.getRect(choice).top - tester.getRect(type).bottom,
      closeTo(14, 0.1),
    );
    expect(h.api.writes, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('320px inventory and create settings support 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = await _pump(tester, scale: 2);
    expect(tester.takeException(), isNull);
    final create = find.widgetWithText(FilledButton, 'Create virtual machine');
    await _reveal(tester, create);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(h.api.writes, 0);
  });
  testWidgets(
    'unsupported account renders without starting inventory retry timers',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [virtualMachinesSessionProvider.overrideWithValue(null)],
          child: MaterialApp(
            theme: TrueNavoTheme.dark(),
            home: const VirtualMachinesPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connect to manage virtual machines.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );
  for (final label in ['Delete', 'Create virtual machine', 'Add device']) {
    testWidgets('profile change hides all values in $label dialog', (
      tester,
    ) async {
      final h = await _pump(tester);
      final target = label == 'Create virtual machine'
          ? find.widgetWithText(FilledButton, label)
          : find.widgetWithText(OutlinedButton, label);
      await _reveal(tester, target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      h.active = null;
      h.container.invalidate(dashboardActiveSessionProvider);
      await tester.pumpAndSettle();
      expect(find.text('Connection changed'), findsOneWidget);
      expect(find.text('guest'), findsNothing);
      expect(find.text('Confirm reviewed change'), findsNothing);
      expect(find.text('Review settings'), findsNothing);
      expect(find.text('Review device'), findsNothing);
      expect(h.api.writes, 0);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    });
  }
  testWidgets('delete requires exact typed name and backing-storage warning', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _reveal(tester, find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Backing zvols and files are retained.'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, 'Confirm reviewed change');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, 'GUEST');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, 'guest');
    await tester.pump();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(h.api.writes, 1);
    expect(h.api.confirmation, 'guest');
  });
  testWidgets('read-only inventory does not offer lifecycle writes', (
    tester,
  ) async {
    final h = await _pump(tester, readonly: true);
    expect(find.text('Read-only VM account'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Delete'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create virtual machine'),
          )
          .onPressed,
      isNull,
    );
    expect(h.api.writes, 0);
  });
  testWidgets(
    'create opens real CPU memory firmware settings and remains read-only until review',
    (tester) async {
      final h = await _pump(tester);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Create virtual machine'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Create VM · settings'), findsOneWidget);
      expect(find.text('Memory (MiB)'), findsOneWidget);
      expect(find.text('CPU sockets'), findsOneWidget);
      expect(find.text('Boot firmware'), findsOneWidget);
      expect(h.api.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('device wizard selects issued storage and interface choices', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _reveal(tester, find.widgetWithText(OutlinedButton, 'Add device'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add device'));
    await tester.pumpAndSettle();
    expect(find.text('Unused existing zvol'), findsOneWidget);
    expect(find.text('Review device'), findsOneWidget);
    expect(h.api.writes, 0);
    expect(tester.takeException(), isNull);
  });
}

class _Harness {
  _Harness({bool readonly = false}) {
    api.readonly = readonly;
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      version: '25.10.1',
      endpoint: 'wss://fixture.example/api/current',
    );
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final api = _Fake();
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  VirtualMachinesController get controller =>
      container.read(virtualMachinesControllerProvider.notifier);
  VirtualMachinesState get state =>
      container.read(virtualMachinesControllerProvider);
  ServerOperationLock get lock => container.read(serverOperationLockProvider);
  Future<void> execute() => controller.execute(session, _review, 'guest');
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  bool readonly = false,
  double scale = 1,
}) async {
  final h = _Harness(readonly: readonly);
  addTearDown(h.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const VirtualMachinesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

class _Fake implements SessionRepository, AuthenticatedVirtualMachinesSession {
  bool readonly = false;
  int writes = 0, polls = 0;
  String? confirmation;
  Future<VmOperationResult> Function()? onWrite;
  @override
  VmCapabilities get virtualMachineCapabilities => VmCapabilities(
    connected: true,
    versionSupported: true,
    methods: readonly
        ? const {'vm.query'}
        : const {
            'vm.query',
            'vm.create',
            'vm.update',
            'vm.delete',
            'vm.start',
            'vm.device.create',
            'vm.device.update',
            'vm.device.delete',
          },
  );
  @override
  Future<VmInventory> loadVirtualMachines() async => VmInventory(
    machines: [
      VirtualMachine(
        id: 1,
        uuid: '11111111-1111-4111-8111-111111111111',
        configuration: const VmConfiguration(name: 'guest', memoryMiB: 2048),
        state: 'STOPPED',
        devices: const [],
      ),
    ],
  );
  @override
  Future<VmChoices> loadVmChoices() async => VmChoices(
    maximumVcpus: 64,
    availableMemoryBytes: 16 * 1024 * 1024 * 1024,
    cpuModels: const ['qemu64'],
    disks: const [
      VmDeviceOption(
        kind: 'DISK',
        value: '/dev/zvol/tank/free',
        label: 'tank/free',
      ),
    ],
    interfaces: const [
      VmDeviceOption(kind: 'NIC', value: 'br0', label: 'Bridge br0'),
    ],
  );
  @override
  Future<VmReview> reviewVmAction(VirtualMachine vm, VmAction action) async =>
      _review;
  @override
  Future<VmOperationResult> executeVmReview(
    VmReview review, {
    required String confirmation,
  }) async {
    writes++;
    this.confirmation = confirmation;
    return onWrite == null
        ? const VmOperationResult(outcome: VmOperationOutcome.verified)
        : onWrite!();
  }

  @override
  Future<VmOperationResult> pollVmOperation(VmOperationHandle operation) async {
    expect(operation, same(_handle));
    polls++;
    return const VmOperationResult(outcome: VmOperationOutcome.verified);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preview with VirtualMachinesPreviewAdapter {}
