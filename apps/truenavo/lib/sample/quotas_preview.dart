// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Constant-compatible mixin with synthetic presentation data only.
/// No transport or credential access; no review or mutation is authorized.
mixin QuotasPreviewAdapter implements AuthenticatedQuotasSession {
  static const datasets = [
    QuotaDataset(id: 'tank/shared', guid: '4101'),
    QuotaDataset(id: 'tank/archive', guid: '4102'),
  ];

  @override
  QuotaCapabilities get quotaCapabilities => const QuotaCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
    canSetUser: true,
    canSetGroup: true,
  );

  @override
  Future<List<QuotaDataset>> loadQuotaDatasets() async => datasets;

  @override
  Future<QuotaInventory> loadQuotas(QuotaDataset dataset) async =>
      QuotaInventory(
        dataset: dataset,
        entries: const [
          QuotaEntry(
            kind: QuotaKind.user,
            id: 1000,
            name: 'alex',
            byteLimit: 107374182400,
            objectLimit: 100000,
            usedBytes: 37580963840,
            usedObjects: 28500,
          ),
          QuotaEntry(
            kind: QuotaKind.user,
            id: 1001,
            name: 'backup',
            byteLimit: 0,
            objectLimit: 0,
            usedBytes: 12884901888,
            usedObjects: 8400,
          ),
          QuotaEntry(
            kind: QuotaKind.user,
            id: 1002,
            name: 'new-editor',
            byteLimit: 21474836480,
            objectLimit: 10000,
          ),
          QuotaEntry(
            kind: QuotaKind.group,
            id: 2000,
            name: 'studio',
            byteLimit: 536870912000,
            objectLimit: 250000,
            usedBytes: 343597383680,
            usedObjects: 160000,
          ),
          QuotaEntry(
            kind: QuotaKind.group,
            id: 2001,
            name: 'reviewers',
            byteLimit: 53687091200,
            objectLimit: 20000,
            usedBytes: 60129542144,
            usedObjects: 18000,
          ),
        ],
      );

  @override
  Future<QuotaIdentity> resolveQuotaIdentity(
    QuotaInventory inventory,
    QuotaKind kind,
    int id,
  ) async {
    final entry = inventory.entry(kind, id);
    if (entry == null) {
      throw const QuotaException(QuotaExceptionReason.unavailable);
    }
    return QuotaIdentity(
      kind: kind,
      id: id,
      name: entry.name!,
      source: 'LOCAL',
      local: true,
    );
  }

  @override
  Future<QuotaReview> reviewQuotaChange(QuotaChange change) => Future.error(
    const QuotaException(QuotaExceptionReason.unavailableMethod),
  );

  @override
  Future<QuotaResult> executeQuotaReview(
    QuotaReview review,
    String confirmation,
  ) async => const QuotaResult(
    QuotaOutcome.rejected,
    'Synthetic preview: quota changes are disabled.',
  );
}
