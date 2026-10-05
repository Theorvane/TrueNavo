import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/management_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const _command = ServiceControlCommand(
  service: 'ssh',
  action: ServiceControlAction.restart,
);

void main() {
  test(
    'submits once and blocks a duplicate while the first write is pending',
    () async {
      final completion = Completer<ManagementResult>();
      final harness = _Harness(_Manager(onExecute: (_) => completion.future));
      addTearDown(harness.dispose);

      final first = harness.execute();
      expect(harness.state.busy, isTrue);
      await harness.execute();
      expect(harness.manager.commands, [_command]);

      completion.complete(const ManagementCompleted(_command));
      await first;
      expect(harness.state.phase, ManagementPhase.completed);
      expect(harness.state.serverLabel, 'wss://nas.example/api/current');
      expect(harness.manager.polledJobs, isEmpty);
    },
  );

  test(
    'rejects a stale confirmation even for another session of the same profile',
    () async {
      final harness = _Harness(_Manager());
      addTearDown(harness.dispose);
      harness.switchSession(_session(harness.manager));

      await harness.execute();

      expect(harness.manager.commands, isEmpty);
      expect(harness.state.phase, ManagementPhase.failed);
      expect(harness.state.message, contains('connection changed'));
    },
  );

  test('rejects a confirmation after disconnection without a write', () async {
    final harness = _Harness(_Manager());
    addTearDown(harness.dispose);
    harness.switchSession(null);

    await harness.execute();

    expect(harness.manager.commands, isEmpty);
    expect(harness.state.phase, ManagementPhase.failed);
  });

  test(
    'contains a version preflight rejection and never polls or retries it',
    () async {
      final harness = _Harness(
        _Manager(
          onExecute: (_) async {
            throw const ManagementException(
              ManagementExceptionReason.unsupportedVersion,
            );
          },
        ),
      );
      addTearDown(harness.dispose);

      await harness.execute();

      expect(harness.state.phase, ManagementPhase.failed);
      expect(harness.state.message, contains('server version'));
      expect(harness.manager.commands, [_command]);
      expect(harness.manager.polledJobs, isEmpty);
    },
  );

  test(
    'polls the exact accepted job until the server confirms completion',
    () async {
      const submitted = ManagementJobSubmitted(_command, jobId: 17);
      var polls = 0;
      final harness = _Harness(
        _Manager(
          onExecute: (_) async => submitted,
          onPoll: (job) async =>
              ++polls == 1 ? job : const ManagementCompleted(_command),
        ),
      );
      addTearDown(harness.dispose);

      await harness.execute();

      expect(harness.manager.commands, [_command]);
      expect(harness.manager.polledJobs, [submitted, submitted]);
      expect(harness.state.phase, ManagementPhase.completed);
      expect(harness.state.result, isA<ManagementCompleted>());
    },
  );

  test('reports a server job failure without resending the mutation', () async {
    final harness = _Harness(
      _Manager(
        onExecute: (_) async =>
            const ManagementJobSubmitted(_command, jobId: 18),
        onPoll: (_) async => const ManagementFailed(
          _command,
          reason: ManagementFailureReason.operationFailed,
        ),
      ),
    );
    addTearDown(harness.dispose);

    await harness.execute();

    expect(harness.state.phase, ManagementPhase.failed);
    expect(harness.state.message, contains('action failed'));
    expect(harness.manager.commands, [_command]);
    expect(harness.manager.polledJobs, hasLength(1));
  });

  test(
    'bounds pending job polling and explicitly preserves uncertainty',
    () async {
      final harness = _Harness(
        _Manager(
          onExecute: (_) async =>
              const ManagementJobSubmitted(_command, jobId: 19),
          onPoll: (job) async => job,
        ),
      );
      addTearDown(harness.dispose);

      await harness.execute();

      expect(harness.manager.commands, [_command]);
      expect(harness.manager.polledJobs, hasLength(30));
      expect(harness.state.phase, ManagementPhase.unknown);
      expect(harness.state.message, contains('Job #19 is still pending'));
      expect(harness.state.message, contains('No command was resent'));
    },
  );

  test(
    'switching servers while waiting stops all subsequent job requests',
    () async {
      final delay = Completer<void>();
      final enteredDelay = Completer<void>();
      final harness = _Harness(
        _Manager(
          onExecute: (_) async =>
              const ManagementJobSubmitted(_command, jobId: 20),
        ),
        delay: () {
          enteredDelay.complete();
          return delay.future;
        },
      );
      addTearDown(harness.dispose);
      final operation = harness.execute();
      await enteredDelay.future;

      harness.switchSession(_session(_Manager(), profileId: 'other-nas'));
      delay.complete();
      await operation;

      expect(harness.state.phase, ManagementPhase.unknown);
      expect(harness.state.message, contains('original server'));
      expect(harness.manager.commands, [_command]);
      expect(harness.manager.polledJobs, isEmpty);
    },
  );

  test(
    'an uncertain transport failure is never retried or reported successful',
    () async {
      final harness = _Harness(
        _Manager(
          onExecute: (_) async {
            throw TimeoutException(
              'Private transport details must not reach UI',
            );
          },
        ),
      );
      addTearDown(harness.dispose);

      await harness.execute();

      expect(harness.state.phase, ManagementPhase.unknown);
      expect(harness.state.message, contains('No command was resent'));
      expect(harness.state.message, isNot(contains('Private transport')));
      expect(harness.manager.commands, [_command]);
      expect(harness.manager.polledJobs, isEmpty);
    },
  );

  test('a typed unknown result remains unknown without polling', () async {
    final harness = _Harness(
      _Manager(
        onExecute: (_) async => const ManagementOutcomeUnknown(_command),
      ),
    );
    addTearDown(harness.dispose);

    await harness.execute();

    expect(harness.state.phase, ManagementPhase.unknown);
    expect(harness.state.busy, isFalse);
    expect(harness.manager.commands, [_command]);
    expect(harness.manager.polledJobs, isEmpty);
  });

  test(
    'a typed polling exception remains uncertain after a job was accepted',
    () async {
      const submitted = ManagementJobSubmitted(_command, jobId: 43);
      final harness = _Harness(
        _Manager(
          onExecute: (_) async => submitted,
          onPoll: (_) async => throw const ManagementException(
            ManagementExceptionReason.staleSession,
          ),
        ),
      );
      addTearDown(harness.dispose);

      await harness.execute();

      expect(harness.state.phase, ManagementPhase.unknown);
      expect(harness.state.result, same(submitted));
      expect(harness.manager.commands, [_command]);
      expect(harness.manager.polledJobs, [submitted]);
    },
  );

  test(
    'a thrown poll error preserves the accepted job for manual verification',
    () async {
      const submitted = ManagementJobSubmitted(_command, jobId: 42);
      final harness = _Harness(
        _Manager(
          onExecute: (_) async => submitted,
          onPoll: (_) async =>
              throw TimeoutException('Private job transport details'),
        ),
      );
      addTearDown(harness.dispose);

      await harness.execute();

      expect(harness.state.phase, ManagementPhase.unknown);
      expect(harness.state.result, same(submitted));
      expect((harness.state.result as ManagementJobSubmitted).jobId, 42);
      expect(harness.state.message, isNot(contains('Private job transport')));
      expect(harness.manager.commands, [_command]);
      expect(harness.manager.polledJobs, [submitted]);
    },
  );
}

AuthenticatedSession _session(_Manager manager, {String profileId = 'nas'}) =>
    AuthenticatedSession(
      profileId: profileId,
      repository: manager,
      availableMethodNames: const {'service.control', 'core.get_jobs'},
      version: '25.10.1',
    );

class _Harness {
  _Harness(this.manager, {Future<void> Function()? delay}) {
    session = _session(manager);
    active = session;
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => active),
        managementPollDelayProvider.overrideWithValue(delay ?? () async {}),
      ],
    );
  }

  final _Manager manager;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  ManagementState get state => container.read(managementControllerProvider);
  Future<void> execute() => container
      .read(managementControllerProvider.notifier)
      .execute(
        expectedSession: session,
        serverLabel: 'wss://nas.example/api/current',
        command: _command,
      );
  void switchSession(AuthenticatedSession? session) {
    active = session;
    container.invalidate(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}

class _Manager implements SessionRepository, AuthenticatedSessionManagement {
  _Manager({this.onExecute, this.onPoll});
  final Future<ManagementResult> Function(ManagementCommand)? onExecute;
  final Future<ManagementResult> Function(ManagementJobSubmitted)? onPoll;
  final commands = <ManagementCommand>[];
  final polledJobs = <ManagementJobSubmitted>[];
  @override
  ManagementCapabilities get managementCapabilities => ManagementCapabilities(
    connected: true,
    versionSupported: true,
    availableActions: ManagementAction.values.toSet(),
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
