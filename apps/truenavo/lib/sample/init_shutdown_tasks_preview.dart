// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

import 'scheduled_tasks_preview_readiness.dart';

/// Header-only fixture. Never registers commands or initiates a lifecycle event.
mixin InitShutdownTasksPreviewAdapter
    implements AuthenticatedInitShutdownTasksSession {
  static final _inventory = InitShutdownTasksInventory(
    readiness: scheduledTasksPreviewReadiness,
    tasks: const [
      InitShutdownTaskSnapshot(
        id: 21,
        type: 'COMMAND',
        phase: InitShutdownTaskPhase.preinit,
        enabled: false,
        timeoutSeconds: 30,
      ),
      InitShutdownTaskSnapshot(
        id: 22,
        type: 'COMMAND',
        phase: InitShutdownTaskPhase.postinit,
        enabled: true,
        timeoutSeconds: 60,
      ),
      InitShutdownTaskSnapshot(
        id: 23,
        type: 'COMMAND',
        phase: InitShutdownTaskPhase.shutdown,
        enabled: false,
        timeoutSeconds: 45,
      ),
      InitShutdownTaskSnapshot(
        id: 24,
        type: 'SCRIPT',
        phase: InitShutdownTaskPhase.postinit,
        enabled: false,
        timeoutSeconds: 10,
      ),
    ],
  );
  @override
  InitShutdownTasksCapabilities get initShutdownTasksCapabilities =>
      const InitShutdownTasksCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
      );
  @override
  Future<InitShutdownTasksInventory> loadInitShutdownTasks() async =>
      _inventory;
  @override
  Future<InitShutdownTasksReview> reviewInitShutdownTasks(
    InitShutdownTasksRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      request.command?.dispose();
      throw const InitShutdownTasksException(
        InitShutdownTasksExceptionReason.invalidRequest,
      );
    }
    return InitShutdownTasksReview(
      request: request,
      endpoint: _inventory.endpoint,
      // Fixed synthetic marker, not a digest of any command or secret.
      commandReference:
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      warnings: const [
        'SAMPLE ONLY. No command, script, boot or shutdown operation is performed.',
        'Real enabled commands run with system authority. A wait budget does not guarantee that a command or its descendants stop.',
        'Disabling or deleting a task does not cancel already selected or running commands.',
      ],
    );
  }

  @override
  Future<InitShutdownTasksResult> executeInitShutdownTasks(
    InitShutdownTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    review.request.command?.dispose();
    return const InitShutdownTasksResult(
      InitShutdownTasksOutcome.rejected,
      'Sample preview: no lifecycle task, command, script, boot or shutdown was changed or executed.',
    );
  }
}
