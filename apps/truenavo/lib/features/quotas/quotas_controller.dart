import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final quotasSessionProvider = Provider<AuthenticatedQuotasSession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedQuotasSession
      ? repository as AuthenticatedQuotasSession
      : null;
});

final quotaDatasetsProvider = FutureProvider<List<QuotaDataset>>((ref) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final api = ref.watch(quotasSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw const QuotaException(QuotaExceptionReason.notAuthenticated);
  }
  return api.loadQuotaDatasets();
}, retry: (_, _) => null);

FutureProvider<QuotaInventory> quotaInventoryProvider(QuotaDataset dataset) =>
    _quotaInventoryByIdentityProvider((id: dataset.id, guid: dataset.guid));

final _quotaInventoryByIdentityProvider = FutureProvider.autoDispose
    .family<QuotaInventory, ({String id, String guid})>((ref, dataset) async {
      // A new authenticated session can reuse a repository object.
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = ref.watch(quotasSessionProvider);
      if (session?.endpoint == null || api == null) {
        throw const QuotaException(QuotaExceptionReason.notAuthenticated);
      }
      final datasets = await ref.watch(quotaDatasetsProvider.future);
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        throw const QuotaException(QuotaExceptionReason.stale);
      }
      final current = datasets
          .where((item) => item.id == dataset.id && item.guid == dataset.guid)
          .firstOrNull;
      if (current == null || !current.editable) {
        throw const QuotaException(QuotaExceptionReason.stale);
      }
      return api.loadQuotas(current);
    }, retry: (_, _) => null);

final class QuotasState {
  const QuotasState({
    this.busy = false,
    this.result,
    this.target,
    this.server,
    this.identity,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final QuotaResult? result;
  final String? target, server, identity;
  bool get unknown => result?.outcome == QuotaOutcome.unknown;
  bool get locked => busy || unknown;
}

final quotasControllerProvider =
    NotifierProvider<QuotasController, QuotasState>(QuotasController.new);

class QuotasController extends Notifier<QuotasState> {
  AuthenticatedSession? _operationSession;
  ServerOperationLock? _lock;
  Object? _owner;
  var _generation = 0;

  @override
  QuotasState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      state = state.locked
          ? QuotasState(
              target: state.target,
              server: state.server,
              identity: state.identity,
              connectionCurrent: false,
              result: const QuotaResult(
                QuotaOutcome.unknown,
                'The connection changed before this quota change was verified. '
                'Inspect the original dataset and identity before making '
                'another change.',
              ),
            )
          : const QuotasState();
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const QuotasState();
  }

  Future<void> execute(
    AuthenticatedSession session,
    QuotaReview review,
    String confirmation,
  ) async {
    if (state.locked ||
        confirmation != review.confirmation ||
        session.endpoint == null ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final api = session.repository;
    if (api is! AuthenticatedQuotasSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const QuotasState(
        result: QuotaResult(
          QuotaOutcome.rejected,
          'Another server operation is in progress.',
        ),
      );
      return;
    }
    _operationSession = session;
    final generation = ++_generation;
    state = QuotasState(
      busy: true,
      target: review.target,
      server: session.endpoint,
      identity: review.identity.displayLabel,
    );
    QuotaResult result;
    try {
      result = await (api as AuthenticatedQuotasSession).executeQuotaReview(
        review,
        confirmation,
      );
    } on QuotaException catch (error) {
      result = QuotaResult(QuotaOutcome.rejected, error.userMessage);
    } on Object {
      result = const QuotaResult(
        QuotaOutcome.unknown,
        'The quota change could not be verified. Inspect the original dataset '
        'and identity, then reconnect. Do not repeat the change.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = QuotasState(
      result: result,
      target: review.target,
      server: session.endpoint,
      identity: review.identity.displayLabel,
    );
    if (!state.unknown) _release();
    ref.invalidate(quotaInventoryProvider(review.dataset));
  }

  bool get canAcknowledge {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unknown &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        current!.endpoint == state.server &&
        !identical(current, _operationSession);
  }

  /// Only acknowledges an inspection; never determines or replays the outcome.
  void acknowledgeAfterReconnect() {
    if (!canAcknowledge) return;
    _release();
    state = const QuotasState();
    ref.invalidate(quotaDatasetsProvider);
  }

  void _release() {
    final owner = _owner;
    if (owner != null) _lock?.release(owner);
    _owner = null;
  }
}
