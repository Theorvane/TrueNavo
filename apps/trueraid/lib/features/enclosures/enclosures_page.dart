import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';
import 'enclosure_inventory.dart';
import 'enclosure_slot_details.dart';

final enclosureInventoryProvider = FutureProvider<EnclosureInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null || repository is! AuthenticatedAdminSession) {
    throw StateError('Connect to a server to view enclosures.');
  }
  final api = repository as AuthenticatedAdminSession;
  final method = api.adminCatalog.method('webui.enclosure.dashboard');
  if (method == null ||
      !method.supported ||
      !api.adminCatalog.versionSupported) {
    throw StateError('This server does not support the enclosure dashboard.');
  }
  final result = await api.invokeAdmin(
    AdminRequest(method: method, arguments: const []),
  );
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider))) {
    throw StateError('The server connection changed.');
  }
  if (result is! AdminCompleted) {
    throw StateError('Enclosure inventory is unavailable for this account.');
  }
  return EnclosureInventory.parse(result.value);
}, retry: (_, _) => null);

class EnclosuresPage extends ConsumerWidget {
  const EnclosuresPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inventory = ref.watch(enclosureInventoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enclosures'),
        actions: [
          IconButton(
            key: const Key('enclosures-refresh'),
            tooltip: 'Reload enclosure inventory',
            onPressed: inventory.isLoading
                ? null
                : () => ref.invalidate(enclosureInventoryProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              children: [
                const Text('SYSTEM · HARDWARE', style: TdTypography.micro),
                const SizedBox(height: 8),
                const Text('Chassis & slots', style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'Passive layout reported by TrueNAS. Slot positions are ordered by server slot number, not a verified physical front/rear drawing. No identify or fault light command is sent.',
                ),
                const SizedBox(height: 20),
                switch (inventory) {
                  AsyncData(:final value) when value.enclosures.isEmpty =>
                    const TdPanel(
                      title: 'No enclosures reported',
                      child: Text(
                        'TrueNAS reports enclosure layouts only on supported TrueNAS hardware.',
                      ),
                    ),
                  AsyncData(:final value) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final enclosure in value.enclosures) ...[
                        _EnclosureCard(enclosure: enclosure),
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
                  AsyncError(:final error) => TdPanel(
                    title: 'Enclosure inventory unavailable',
                    child: Text(
                      error is StateError ? error.message.toString() : 'The server did not return a usable enclosure layout. Reload to try again.',
                    ),
                  ),
                  _ => const Center(child: CircularProgressIndicator()),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EnclosureCard extends StatelessWidget {
  const _EnclosureCard({required this.enclosure});
  final EnclosureSnapshot enclosure;

  @override
  Widget build(BuildContext context) {
    final occupied = enclosure.slots.where((slot) => slot.occupied).length;
    final attention = enclosure.slots
        .where((slot) => slot.occupied && !slot.healthy)
        .length;
    return TdPanel(
      title: enclosure.name,
      description:
          '${enclosure.controller ? 'Controller' : 'Expansion'} · ${enclosure.model} · ${enclosure.status}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${enclosure.slots.length} reported slots · $occupied occupied · $attention needing attention',
          ),
          if (enclosure.slots.isNotEmpty) ...[
            const SizedBox(height: 8),
            Semantics(
              label:
                  'Reported slot occupancy: $occupied of ${enclosure.slots.length}',
              child: LinearProgressIndicator(
                key: const Key('enclosure-occupancy'),
                value: occupied / enclosure.slots.length,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'Declared capacity: ${enclosure.frontSlots} front · ${enclosure.rearSlots} rear · ${enclosure.internalSlots} internal',
          ),
          const SizedBox(height: 16),
          if (enclosure.slots.isEmpty)
            const Text('No per-slot details were reported.')
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth < 520
                    ? constraints.maxWidth
                    : 230.0;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final slot in enclosure.slots)
                      SizedBox(
                        width: width,
                        child: _SlotCard(slot: slot),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SlotCard extends StatelessWidget {
  const _SlotCard({required this.slot});
  final EnclosureSlot slot;

  @override
  Widget build(BuildContext context) {
    final color = !slot.occupied
        ? Theme.of(context).colorScheme.outline
        : slot.healthy
        ? Colors.green
        : Theme.of(context).colorScheme.error;
    return Semantics(
      label:
          'Slot ${slot.number}, ${slot.status}, ${slot.occupied ? slot.device : 'empty'}',
      child: InkWell(
        key: Key('enclosure-slot-${slot.number}'),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => EnclosureSlotDetails(slot: slot),
        ),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    slot.occupied ? Icons.storage : Icons.crop_square,
                    size: 18,
                    color: color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      slot.descriptor,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text('#${slot.number}'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                slot.occupied ? '${slot.device} · ${slot.status}' : slot.status,
              ),
              if (slot.model.isNotEmpty)
                Text(slot.model, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (slot.pool.isNotEmpty)
                Text('Pool: ${slot.pool} · ${slot.diskStatus}'),
            ],
          ),
        ),
      ),
    );
  }
}
