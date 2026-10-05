import 'dart:convert';

import 'nvme_tcp_bind_address.dart';

final class NvmePortAddressChoice {
  const NvmePortAddressChoice(this.address, this.description);
  final String address, description;
}

/// Bounded transport-address descriptions, not a hardware/reachability probe.
final class NvmePortAddressChoices {
  NvmePortAddressChoices._(
    this.transport,
    this.choices,
    this.excludedCount,
    this.proof,
  );
  final String transport, proof;
  final List<NvmePortAddressChoice> choices;
  final int excludedCount;
  bool contains(String address) =>
      choices.any((c) => NvmeTcpBindAddress.equivalent(c.address, address));

  static NvmePortAddressChoices parse(String transport, Object? value) {
    if (!const {'TCP', 'RDMA'}.contains(transport) ||
        value is! Map ||
        value.length > 100) {
      throw StateError(
        'Transport address choices are unavailable or exceed the verification bound.',
      );
    }
    final entries = <NvmePortAddressChoice>[];
    final proofRows = <List<String>>[];
    final identities = <String>{};
    var excluded = 0;
    for (final entry in value.entries) {
      final address = entry.key, description = entry.value;
      if (address is! String ||
          address.length > 256 ||
          description is! String ||
          description.length > 256 ||
          address.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
          description.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw StateError('Malformed transport address choices.');
      }
      proofRows.add([address, description]);
      final parsed = NvmeTcpBindAddress.parse(address);
      if (parsed?.creatable != true) {
        excluded++;
        continue;
      }
      if (!identities.add(parsed!.identity)) {
        throw StateError('Ambiguous equivalent transport address choices.');
      }
      entries.add(NvmePortAddressChoice(address, description));
    }
    entries.sort((a, b) => a.address.compareTo(b.address));
    proofRows.sort((a, b) => a.first.compareTo(b.first));
    return NvmePortAddressChoices._(
      transport,
      List.unmodifiable(entries),
      excluded,
      jsonEncode([transport, proofRows]),
    );
  }
}
